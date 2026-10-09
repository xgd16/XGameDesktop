import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../native/wallpaper_engine.dart';

/// The last segment of a Windows or POSIX path.
String _basename(String path) =>
    path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;

/// Serves a wallpaper to the in-app browser — the renderer included.
///
/// Two kinds of wallpaper need this. A *scene* is not a picture but a small
/// program: `scene.pkg` holds the scene graph, its shaders and textures, and
/// only a renderer turns it into the moving wallpaper. A *web* wallpaper is the
/// author's own page, and it is loaded through the server rather than as a
/// `file://` URL for a blunt reason: a file page has an opaque origin, and the
/// browser then refuses its own module scripts, stylesheets and fetches.
/// Wallpaper Engine gets away with opening the file directly only because its
/// browser runs with the web security switched off. Served from `127.0.0.1`,
/// the page has a real origin and its relative paths just work.
///
/// The renderer used for scenes is `webwallgl` (MIT), which runs on WebGL2 —
/// the in-app browser has that — and asks its host for exactly two files:
/// `scene.pkg` and `project.json`. A page cannot read the disk, so those are
/// served over a loopback socket, along with the renderer itself and, when a
/// Wallpaper Engine installation is around, the engine's own material library
/// (some scenes reference stock textures from it — a snowflake, say — instead
/// of shipping their own).
///
/// Nothing listens beyond `127.0.0.1`, and only folders registered through
/// [registerScene] and [registerPage] are readable at all.
class WallpaperServer {
  WallpaperServer._(this._server) {
    _server.listen(_handle, onError: (Object _) {});
  }

  final HttpServer _server;
  final Map<String, Directory> _roots = {};
  final Map<String, String> _ids = {};
  String? _materialsJson;
  String? _materialsFor;
  Uint8List? _rendererBytes;

  /// Test seam: stands in for Wallpaper Engine's `assets` folder.
  static Directory? assetsDirOverride;

  static WallpaperServer? _shared;
  static Future<WallpaperServer?>? _starting;

  int get port => _server.port;

  static Future<WallpaperServer> start() async =>
      WallpaperServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  /// The app-wide instance. Null when the loopback socket cannot be bound —
  /// the scene then stays a still picture and a page falls back to `file://`.
  static Future<WallpaperServer?> shared() {
    final running = _shared;
    if (running != null) return Future.value(running);
    return _starting ??= start().then<WallpaperServer?>((server) {
      _shared = server;
      _starting = null;
      return server;
    }).catchError((Object _) {
      _starting = null;
      return null;
    });
  }

  /// The URL of the page that renders the scene in [pkgPath], or null when the
  /// server could not start.
  static Future<String?> scenePageUrl(String pkgPath) async =>
      (await shared())?.registerScene(pkgPath);

  /// The URL of the web wallpaper whose entry page is [htmlPath], or null when
  /// the server could not start.
  static Future<String?> webPageUrl(String htmlPath) async =>
      (await shared())?.registerPage(htmlPath);

  /// Registers the folder holding [pkgPath] — it, and only it, becomes
  /// readable — and returns the URL of the page that renders it.
  String registerScene(String pkgPath) {
    final id = _register(File(pkgPath).parent);
    final query = _assetsDir() == null ? '' : '?localAssets=1';
    return '$_origin/scene/$id/$query';
  }

  /// Registers the folder holding [htmlPath], so the page's own `assets/…`
  /// neighbours resolve, and returns the URL the browser should open.
  String registerPage(String htmlPath) {
    final file = File(htmlPath);
    final id = _register(file.parent);
    final name = Uri.encodeComponent(_basename(file.path));
    return '$_origin/web/$id/$name';
  }

  String get _origin => 'http://127.0.0.1:$port';

  String _register(Directory dir) {
    final id = _ids.putIfAbsent(dir.path.toLowerCase(), () => _uniqueId(dir));
    _roots[id] = dir;
    return id;
  }

  Future<void> stop() async {
    _roots.clear();
    _ids.clear();
    if (identical(_shared, this)) _shared = null;
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final segments = request.uri.pathSegments;
      final headOnly = request.method == 'HEAD';
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (segments.length == 2 &&
          segments[0] == 'lib' &&
          segments[1] == 'webwallgl.min.mjs') {
        await _serveRenderer(response, headOnly);
        return;
      }
      if (segments.isNotEmpty &&
          (segments[0] == 'scene' || segments[0] == 'web')) {
        await _serveRoot(response, segments, headOnly, range);
        return;
      }
      if (segments.length >= 2 && segments[0] == 'api' &&
          segments[1] == 'local-assets') {
        await _serveLocalAssets(response, segments, headOnly, range);
        return;
      }
      response.statusCode = HttpStatus.notFound;
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {
        // The response was already on the wire; nothing left to say.
      }
    } finally {
      await response.close();
    }
  }

  Future<void> _serveRoot(HttpResponse response, List<String> segments,
      bool headOnly, String? range) async {
    final kind = segments[0];
    if (segments.length < 2) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    final dir = _roots[segments[1]];
    if (dir == null) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    final rest = segments.sublist(2).where((s) => s.isNotEmpty).toList();
    if (rest.isEmpty) {
      // A scene has no page of its own — the server draws it. A web wallpaper
      // always names its entry file in the URL.
      if (kind != 'scene') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      await _send(response, utf8.encode(_playerPage), 'text/html', headOnly);
      return;
    }
    await _sendFile(response, dir, rest, headOnly, range);
  }

  Future<void> _serveLocalAssets(HttpResponse response, List<String> segments,
      bool headOnly, String? range) async {
    final assets = _assetsDir();
    // `/api/local-assets` — what the renderer asks for before everything else.
    if (segments.length == 2) {
      await _sendJson(
          response,
          assets == null
              ? {'ok': false}
              : {
                  'ok': true,
                  'roots': [
                    {'id': 'we'}
                  ],
                },
          headOnly);
      return;
    }
    // `/api/local-assets/we/materials/index.json` and …/materials/<path>.tex
    if (assets == null ||
        segments.length < 5 ||
        segments[2] != 'we' ||
        segments[3] != 'materials') {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    if (segments.length == 5 && segments[4] == 'index.json') {
      final index = _materialsIndex(assets);
      if (index == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      await _send(response, utf8.encode(index), 'application/json', headOnly);
      return;
    }
    final materials = Directory(
        '${assets.path}${Platform.pathSeparator}materials');
    await _sendFile(response, materials, segments.sublist(4), headOnly, range);
  }

  Future<void> _serveRenderer(HttpResponse response, bool headOnly) async {
    // One load even when the page's first requests arrive together: the bundle
    // is ~100 KB and every scene page asks for it.
    _rendererBytes ??= await (_rendererRequest ??= _rendererAsset().then((b) {
      _rendererRequest = null;
      _rendererBytes = b;
      return b;
    }));
    final bytes = _rendererBytes;
    if (bytes == null) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    await _send(response, bytes, 'text/javascript', headOnly);
  }

  Future<Uint8List?>? _rendererRequest;

  static Future<Uint8List?> _rendererAsset() async {
    try {
      final data = await rootBundle.load('assets/webwallgl.min.mjs');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  /// The only files reachable: those inside [root], whatever the URL says.
  ///
  /// The response is streamed and range-aware. A scene package is tens to
  /// hundreds of MB and the browser's media stack seeks through it by byte
  /// range; buffering the whole file per request both peaked the heap at the
  /// file size and forced a full re-download for every seek.
  Future<void> _sendFile(HttpResponse response, Directory root,
      List<String> segments, bool headOnly, String? range) async {
    // A segment that climbs (`..`), names a drive (`C:`) or is empty is never
    // part of a wallpaper's own files; the prefix check below is the second
    // line of defence rather than the first.
    final safe = segments.isNotEmpty &&
        segments.every((s) =>
            s.isNotEmpty &&
            s != '.' &&
            s != '..' &&
            !s.contains(':') &&
            !s.contains(Platform.pathSeparator) &&
            !s.contains('/'));
    final file = File(
        '${root.path}${Platform.pathSeparator}${segments.join(Platform.pathSeparator)}');
    final rootPath = '${root.absolute.path}${Platform.pathSeparator}'
        .toLowerCase();
    if (!safe ||
        !file.absolute.path.toLowerCase().startsWith(rootPath) ||
        !file.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    await _sendStream(response, file, _contentType(file.path), headOnly, range);
  }

  /// Streams [file], honoring a single byte range (what media players ask
  /// for). HEAD answers with the headers alone.
  Future<void> _sendStream(HttpResponse response, File file, String type,
      bool headOnly, String? range) async {
    final length = file.lengthSync();
    response.headers.contentType = ContentType.parse(type);
    response.headers.set('Cache-Control', _fileCacheControl);
    response.headers.set('Accept-Ranges', 'bytes');
    if (length == 0) {
      response.statusCode = HttpStatus.ok;
      response.headers.contentLength = 0;
      return;
    }

    var start = 0;
    var end = length - 1;
    var status = HttpStatus.ok;
    if (range != null) {
      final parsed = _parseRange(range, length);
      if (parsed == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.contentLength = 0;
        return;
      }
      (start, end) = parsed;
      status = HttpStatus.partialContent;
      response.headers.set('Content-Range', 'bytes $start-$end/$length');
    }
    response.statusCode = status;
    response.headers.contentLength = end - start + 1;
    if (headOnly) return;
    await response.addStream(file.openRead(start, end + 1));
  }

  /// `bytes=start-end`, `bytes=start-` or `bytes=-suffix`. Null when the range
  /// is malformed or outside the file (the caller answers 416).
  static (int, int)? _parseRange(String header, int length) {
    if (!header.startsWith('bytes=') || length == 0) return null;
    final spec = header.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final first = spec.substring(0, dash).trim();
    final last = spec.substring(dash + 1).trim();
    int start;
    int end;
    if (first.isEmpty) {
      // Suffix form: the last N bytes.
      final suffix = int.tryParse(last);
      if (suffix == null || suffix <= 0) return null;
      start = suffix >= length ? 0 : length - suffix;
      end = length - 1;
    } else {
      final parsedStart = int.tryParse(first);
      if (parsedStart == null || parsedStart < 0 || parsedStart >= length) {
        return null;
      }
      start = parsedStart;
      end = length - 1;
      if (last.isNotEmpty) {
        final parsedEnd = int.tryParse(last);
        if (parsedEnd == null || parsedEnd < start) return null;
        if (parsedEnd < end) end = parsedEnd;
      }
    }
    return (start, end);
  }

  /// Wallpaper files are static for as long as the app runs, and the URLs carry
  /// the wallpaper's own id — so a short private cache is safe, and it is what
  /// keeps a recreated webview (or the settings preview) from re-downloading
  /// every asset from disk. `no-store` was the opposite: every rebuild of the
  /// browser fetched the lot again.
  static const _fileCacheControl = 'private, max-age=300';

  Future<void> _sendJson(
          HttpResponse response, Object json, bool headOnly) async =>
      _send(response, utf8.encode(jsonEncode(json)), 'application/json',
          headOnly);

  Future<void> _send(HttpResponse response, List<int> bytes, String type,
      bool headOnly) async {
    response.headers.contentType = ContentType.parse(type);
    // Served pages, JSON and the renderer are as static as the files are, and
    // every URL carries the wallpaper's own id — no-store only forced the
    // browser to fetch them all again each time it was recreated.
    response.headers.set('Cache-Control', _fileCacheControl);
    response.contentLength = bytes.length;
    if (!headOnly) response.add(bytes);
  }

  /// Wallpaper Engine's shared material library, when the engine is installed.
  /// Null is a perfectly good answer: the renderer keeps its own defaults.
  ///
  /// This is on the path of every material request the renderer makes, so the
  /// installation lookup (registry + Steam libraries) is the memoized one.
  Directory? _assetsDir() {
    final override = assetsDirOverride;
    if (override != null) {
      return override.existsSync() ? override : null;
    }
    final install = WallpaperEngineLibrary.locate()?.installDir;
    if (install == null) return null;
    final dir = Directory('$install${Platform.pathSeparator}assets');
    return dir.existsSync() ? dir : null;
  }

  /// Names of the engine's material textures, as the renderer wants them:
  /// relative to `materials`, without the `.tex` extension.
  String? _materialsIndex(Directory assets) {
    if (_materialsFor == assets.path) return _materialsJson;
    final materials =
        Directory('${assets.path}${Platform.pathSeparator}materials');
    final names = <String>[];
    if (materials.existsSync()) {
      for (final entity in materials.listSync(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path;
        if (!path.toLowerCase().endsWith('.tex')) continue;
        names.add(path
            .substring(materials.path.length + 1, path.length - '.tex'.length)
            .replaceAll(Platform.pathSeparator, '/'));
      }
    }
    names.sort();
    _materialsFor = assets.path;
    _materialsJson = jsonEncode({'names': names});
    return _materialsJson;
  }

  /// A folder name that is safe in a URL, and unique within this server.
  String _uniqueId(Directory dir) {
    final base = _basename(dir.path).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    final slug = base.isEmpty ? 'wallpaper' : base;
    if (!_roots.containsKey(slug) && !_ids.containsValue(slug)) return slug;
    for (var n = 2;; n++) {
      final candidate = '$slug-$n';
      if (!_ids.containsValue(candidate)) return candidate;
    }
  }

  /// A browser is strict about type: a module script served as
  /// `application/octet-stream` is refused, and so is a stylesheet — hence a
  /// real answer for everything a wallpaper's own page may reference.
  static String _contentType(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot).toLowerCase();
    return switch (ext) {
      '.html' || '.htm' => 'text/html; charset=utf-8',
      '.js' || '.mjs' => 'text/javascript; charset=utf-8',
      '.css' => 'text/css; charset=utf-8',
      '.json' || '.map' => 'application/json; charset=utf-8',
      '.xml' => 'application/xml; charset=utf-8',
      '.svg' => 'image/svg+xml',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.ico' => 'image/x-icon',
      '.bmp' => 'image/bmp',
      '.mp4' || '.m4v' => 'video/mp4',
      '.webm' => 'video/webm',
      '.mp3' => 'audio/mpeg',
      '.m4a' || '.aac' => 'audio/mp4',
      '.ogg' || '.oga' => 'audio/ogg',
      '.wav' => 'audio/wav',
      '.flac' => 'audio/flac',
      '.woff2' => 'font/woff2',
      '.woff' => 'font/woff',
      '.ttf' => 'font/ttf',
      '.otf' => 'font/otf',
      '.wasm' => 'application/wasm',
      '.txt' => 'text/plain; charset=utf-8',
      _ => 'application/octet-stream',
    };
  }

  /// The page the browser loads for a scene: a full-bleed canvas, the
  /// renderer, and — if the renderer cannot start — the reason, on screen,
  /// instead of a blank window.
  static const _playerPage = '''
<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>scene</title>
<style>
  html, body { margin: 0; width: 100%; height: 100%; background: transparent;
               overflow: hidden; }
  #wp { display: block; width: 100%; height: 100%; }
  #err { position: fixed; left: 0; right: 0; bottom: 7vh; display: none;
         text-align: center; font: 13px/1.6 "Segoe UI", sans-serif;
         color: rgba(255, 255, 255, 0.8); text-shadow: 0 1px 3px #000; }
</style>
</head>
<body>
<canvas id="wp"></canvas>
<div id="err"></div>
<script type="module">
  const params = new URLSearchParams(location.search);
  const err = document.getElementById('err');
  // The app sends the rate it wants the scene drawn at (its settings page
  // offers a few); a missing or out-of-range value falls back to the budget
  // below.
  const fpsParam = Number(params.get('fps'));
  const fps = Number.isFinite(fpsParam) && fpsParam >= 1 && fpsParam <= 60
      ? fpsParam
      : $_fps;
  const fail = (e) => {
    const msg = String((e && e.message) || e || '未知错误');
    err.textContent = '场景渲染失败 · ' + msg;
    err.style.display = 'block';
    document.title = 'scene-error';
  };
  window.addEventListener('error', (e) => fail(e.error || e.message));
  window.addEventListener('unhandledrejection', (e) => fail(e.reason));
  try {
    const { mount, httpSource } = await import('/lib/webwallgl.min.mjs');
    await mount(document.getElementById('wp'), {
      source: httpSource(location.pathname),
      fit: params.get('fit') === 'contain' ? 'contain' : 'cover',
      fps,
      volume: 0,
    });
    document.title = 'scene-ready';
  } catch (e) {
    fail(e);
  }
</script>
</body>
</html>
''';

  /// A background layer does not need more than this to look alive; the scenes
  /// run bloom, god rays and particles, and the GPU budget is shared with the
  /// app itself.
  static const _fps = 30;
}
