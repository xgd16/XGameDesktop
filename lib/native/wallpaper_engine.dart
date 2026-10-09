import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'scene_pkg.dart';
import 'video_still.dart';
import 'win32_api.dart';

/// Human labels for Wallpaper Engine's project types.
const wallpaperTypeLabels = {
  'video': '视频',
  'scene': '场景',
  'web': '网页',
  'application': '程序',
  'image': '图片',
};

const _imageExts = {
  '.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif', '.tga', '.dds',
};
const _videoExts = {
  '.mp4', '.webm', '.mkv', '.avi', '.mov', '.wmv', '.m4v', '.mpg', '.mpeg',
};
const _webExts = {'.html', '.htm'};

String _ext(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final dot = path.lastIndexOf('.');
  return dot <= slash ? '' : path.substring(dot).toLowerCase();
}

String _basename(String path) =>
    path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;

/// Backslashes throughout, so `File.parent` and string joins behave.
String _normalize(String path) => path.replaceAll('/', r'\');

/// One wallpaper Wallpaper Engine knows about, with the material available for
/// it on disk.
class WallpaperEngineWallpaper {
  const WallpaperEngineWallpaper({
    required this.title,
    required this.type,
    required this.projectDir,
    required this.primaryFile,
    this.previewPath,
  });

  final String title;

  /// project.json's `type`, lower-cased: video / scene / web / application /
  /// image. Empty when no project.json could be found.
  final String type;

  /// The wallpaper's folder — the one holding project.json.
  final String projectDir;

  /// What Wallpaper Engine plays: the .mp4, scene.pkg, index.html, .exe …
  final String primaryFile;

  /// The author's own preview picture (jpg/png/gif), when the project ships
  /// one. This is the closest still that exists for everything the app cannot
  /// render itself.
  final String? previewPath;

  bool get isImage =>
      type == 'image' || _imageExts.contains(_ext(primaryFile));

  bool get isVideo =>
      type == 'video' || _videoExts.contains(_ext(primaryFile));

  /// The file a frame can be decoded from, when this is a video wallpaper.
  String? get videoFile =>
      _videoExts.contains(_ext(primaryFile)) ? primaryFile : null;

  /// The wallpaper is a page, which Wallpaper Engine runs in a browser.
  bool get isWeb => type == 'web' || _webExts.contains(_ext(primaryFile));

  /// The page a web wallpaper starts from.
  String? get webFile =>
      _webExts.contains(_ext(primaryFile)) ? primaryFile : null;

  /// The wallpaper is a scene: Wallpaper Engine draws it from a package.
  bool get isScene => type == 'scene' || _ext(primaryFile) == '.pkg';

  /// The package a scene wallpaper is drawn from.
  String? get scenePkg => _ext(primaryFile) == '.pkg' ? primaryFile : null;

  String get typeLabel => wallpaperTypeLabels[type] ?? '壁纸';
}

/// What [resolveStill] picked, and where it came from.
class WallpaperEngineStill {
  const WallpaperEngineStill({required this.path, required this.kind});

  final String path;

  /// `image` (the wallpaper *is* a picture), `video-frame` (a real frame
  /// decoded from the video), or `preview` (the author's preview picture).
  final String kind;

  bool get isFrame => kind == 'video-frame';
}

/// A Wallpaper Engine installation: where it lives, what it currently has
/// selected, and which wallpapers it knows.
///
/// Everything here is read from files on disk — nothing is launched, nothing
/// is written, and the app works the same whether Wallpaper Engine is running
/// or not.
class WallpaperEngineLibrary {
  WallpaperEngineLibrary({
    required this.installDir,
    required this.configPath,
    this.contentRoots,
  });

  final String installDir;

  /// `<installDir>\config.json` — WE keeps the per-user selection here, not
  /// in the Steam userdata folder.
  final String configPath;

  /// Folders to scan for wallpapers. Null means "work them out": the Steam
  /// library holding this installation, every other Steam library, and the
  /// local project folders. Tests pass a fake tree here.
  final List<String>? contentRoots;

  /// Finds the installation: the `HKCU\Software\WallpaperEngine` key WE itself
  /// writes, then every Steam library's `steamapps\common\wallpaper_engine`.
  /// [roots] replaces that search entirely (tests point it at a fake tree).
  ///
  /// The search reads the registry and every `libraryfolders.vdf` on disk, and
  /// it is asked for far more often than that can change — the settings page
  /// once per visit, and the wallpaper server once per HTTP request. The answer
  /// is memoized for a minute; [roots] always reads the disk.
  static WallpaperEngineLibrary? locate({List<String>? roots}) {
    if (roots != null) return _locate(roots);
    final at = _locatedAt;
    // A "not installed" answer is cached too: the machine without Wallpaper
    // Engine is exactly the one that would otherwise re-read the registry and
    // every libraryfolders.vdf on every call.
    if (at != null && DateTime.now().difference(at) < _locateTtl) {
      return _located;
    }
    final found = _locate(null);
    _located = found;
    _locatedAt = DateTime.now();
    return found;
  }

  static WallpaperEngineLibrary? _locate(List<String>? roots) {
    final candidates = <String>[];
    if (roots != null) {
      for (final root in roots) {
        candidates.add('$root\\steamapps\\common\\wallpaper_engine');
      }
    } else {
      final installPath = readRegistryString(
          hkeyCurrentUser, r'Software\WallpaperEngine', 'installPath');
      if (installPath != null) {
        candidates.add(File(installPath).parent.path);
      }
      for (final root in steamRoots()) {
        candidates.add('$root\\steamapps\\common\\wallpaper_engine');
      }
    }
    for (final dir in candidates) {
      final config = File('$dir\\config.json');
      if (config.existsSync()) {
        return WallpaperEngineLibrary(
            installDir: dir, configPath: config.path);
      }
    }
    return null;
  }

  static WallpaperEngineLibrary? _located;
  static DateTime? _locatedAt;
  static const _locateTtl = Duration(minutes: 1);

  /// Forgets what was read from the registry and the disk, so the next
  /// [locate] and [steamRoots] look again. The settings page calls this on its
  /// explicit refresh: the user may have just installed the engine.
  static void forgetDiscovery() {
    _located = null;
    _locatedAt = null;
    _steamRoots = null;
    _steamRootsAt = null;
  }

  static List<String>? _steamRoots;
  static DateTime? _steamRootsAt;

  /// Steam itself, plus every library folder it knows about. Located through
  /// the registry, so a Steam installed in a custom folder (like ours, on E:)
  /// is still found.
  static List<String> steamRoots() {
    final at = _steamRootsAt;
    final cached = _steamRoots;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _locateTtl) {
      return cached;
    }
    final roots = _steamRootsNow();
    _steamRoots = roots;
    _steamRootsAt = DateTime.now();
    return roots;
  }

  static List<String> _steamRootsNow() {
    final roots = <String>[];
    void add(String? path) {
      if (path == null || path.isEmpty) return;
      final clean = _normalize(path).replaceAll(RegExp(r'\\+$'), '');
      if (!roots.any((r) => r.toLowerCase() == clean.toLowerCase())) {
        roots.add(clean);
      }
    }

    add(readRegistryString(hkeyCurrentUser, r'Software\Valve\Steam', 'SteamPath'));
    add(readRegistryString(
        hkeyLocalMachine, r'SOFTWARE\Valve\Steam', 'InstallPath'));
    add(readRegistryString(hkeyLocalMachine, r'SOFTWARE\Valve\Steam',
        'InstallPath', wow32: true));
    for (final root in List.of(roots)) {
      // add(), not addAll(): the main library is listed in the vdf too.
      for (final library in libraryFolders('$root\\config\\libraryfolders.vdf')) {
        add(library);
      }
    }
    return roots;
  }

  /// Library paths out of libraryfolders.vdf — the modern `"path" "D:\\Games"`
  /// entries, or the older numbered ones when no explicit path is present.
  static List<String> libraryFolders(String vdfPath) {
    final file = File(vdfPath);
    if (!file.existsSync()) return const [];
    try {
      final text = file.readAsStringSync();
      var matches =
          RegExp(r'"path"\s+"([^"]+)"').allMatches(text).map((m) => m.group(1)!);
      if (matches.isEmpty) {
        matches = RegExp(r'^\s*"\d+"\s+"([^"]+)"', multiLine: true)
            .allMatches(text)
            .map((m) => m.group(1)!);
      }
      return [
        for (final value in matches)
          // VDF escapes the separators: "E:\\app\\steam".
          value.replaceAll(r'\\', r'\'),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Where wallpapers live: workshop content in this and every other Steam
  /// library, plus the local project folders.
  List<String> wallpaperRoots() {
    final override = contentRoots;
    if (override != null) return override;
    final roots = <String>[];
    void addWorkshop(String? libraryRoot) {
      if (libraryRoot == null) return;
      final path = '$libraryRoot\\steamapps\\workshop\\content\\431960';
      if (!roots.contains(path)) roots.add(path);
    }

    addWorkshop(_steamLibraryOf(installDir));
    for (final root in steamRoots()) {
      addWorkshop(root);
    }
    roots.add('$installDir\\projects\\myprojects');
    roots.add('$installDir\\projects\\defaultprojects');
    return roots;
  }

  /// `<library>\steamapps\common\wallpaper_engine` → `<library>`.
  static String? _steamLibraryOf(String installDir) {
    var dir = Directory(_normalize(installDir));
    for (var i = 0; i < 3; i++) {
      final up = dir.parent;
      if (up.path == dir.path) return null;
      dir = up;
    }
    return dir.path;
  }

  /// The file Wallpaper Engine has applied on the primary monitor, or null.
  String? currentFile() {
    final Map<String, dynamic> root;
    try {
      root = jsonDecode(File(configPath).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final general = _userNode(root)?['general'];
    if (general is! Map) return null;

    final config = general['wallpaperconfig'];
    final selected = config is Map ? config['selectedwallpapers'] : null;
    final monitor = _monitorKey(general, selected);
    var file = _selectedFile(selected, monitor);

    // Playlists and freshly switched wallpapers have been seen with only the
    // recent list populated; its newest entry is the best answer then.
    if (file == null && general['wallpaperconfigrecent'] is List) {
      for (final entry in general['wallpaperconfigrecent'] as List) {
        final recent = entry is Map ? entry['config'] : null;
        final recentSelected = recent is Map ? recent['selectedwallpapers'] : null;
        file = _selectedFile(recentSelected, monitor) ??
            _selectedFile(recentSelected, null);
        if (file != null) break;
      }
    }
    return file == null ? null : _normalize(file);
  }

  String? _selectedFile(Object? selected, String? monitor) {
    if (selected is! Map) return null;
    if (monitor == null) {
      // Recent entries can be keyed by a monitor that no longer exists.
      for (final value in selected.values) {
        final file = value is Map ? value['file'] : null;
        if (file is String && file.isNotEmpty) return file;
      }
      return null;
    }
    final entry = selected[monitor];
    final file = entry is Map ? entry['file'] : null;
    return file is String && file.isNotEmpty ? file : null;
  }

  /// `general` belongs to the Windows user running WE; fall back to any user
  /// object (a shared machine may have several).
  static Map<String, dynamic>? _userNode(Map<String, dynamic> root) {
    final names = Platform.environment['USERNAME'];
    if (names != null) {
      final mine = root[names];
      if (mine is Map<String, dynamic> && mine['general'] is Map) return mine;
    }
    for (final value in root.values) {
      if (value is Map<String, dynamic> && value['general'] is Map) return value;
    }
    return null;
  }

  /// The monitor whose wallpaper the app adopts: the one WE's browser last
  /// touched, else the first one it has a wallpaper for.
  static String? _monitorKey(Map<dynamic, dynamic> general, Object? selected) {
    if (selected is Map && selected.isNotEmpty) {
      final browser = general['browser'];
      final last = browser is Map ? browser['lastselectedmonitor'] : null;
      if (last is String && selected.containsKey(last)) return last;
      if (selected.containsKey('Monitor0')) return 'Monitor0';
      final keys = selected.keys.whereType<String>().toList()..sort();
      if (keys.isNotEmpty) return keys.first;
    }
    return null;
  }

  /// The wallpaper Wallpaper Engine currently has applied.
  WallpaperEngineWallpaper? current() {
    final file = currentFile();
    return file == null ? null : describe(file);
  }

  /// Every wallpaper this installation knows: the currently applied one first,
  /// then the rest by title. Reads only files, so it works with Wallpaper
  /// Engine closed.
  ///
  /// The folder walk (a listing plus a `project.json` read and up to six
  /// preview probes per wallpaper) is cached until one of the roots changes on
  /// disk — a wallpaper added, removed or renamed moves the folder's own
  /// timestamp. [currentFile] saves the caller's own parse of `config.json`
  /// when it already has one; without it the config is read here.
  List<WallpaperEngineWallpaper> wallpapers({String? currentFile}) {
    final file = currentFile ?? this.currentFile();
    final found = _scanProjects().toList();
    // The selected wallpaper belongs in the list even when its folder lives
    // outside the scanned roots (a wallpaper from another library, say).
    final current = file == null ? null : describe(file);
    if (current != null) {
      found.removeWhere((w) =>
          w.projectDir.toLowerCase() == current.projectDir.toLowerCase());
      found.add(current);
    }
    // One comparator, one pass: the current wallpaper first, then by title.
    final currentDir = current?.projectDir.toLowerCase();
    found.sort((a, b) {
      if (currentDir != null) {
        final aCurrent = a.projectDir.toLowerCase() == currentDir;
        final bCurrent = b.projectDir.toLowerCase() == currentDir;
        if (aCurrent != bCurrent) return aCurrent ? -1 : 1;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return found;
  }

  /// The scanned projects, memoized behind the roots' modification stamps.
  List<WallpaperEngineWallpaper> _scanProjects() {
    final roots = wallpaperRoots();
    final stamp = _stamp(roots);
    final cached = _scanned;
    if (cached != null && stamp == _scannedStamp) return cached;

    final found = <String, WallpaperEngineWallpaper>{};
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync();
      } catch (_) {
        continue;
      }
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final wallpaper = _project(entry.path);
        if (wallpaper != null) {
          found.putIfAbsent(wallpaper.projectDir.toLowerCase(), () => wallpaper);
        }
      }
    }
    final list = found.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    _scanned = list;
    _scannedStamp = stamp;
    return list;
  }

  List<WallpaperEngineWallpaper>? _scanned;
  String? _scannedStamp;

  /// `roots` plus each root's modification time — one stat per root instead of
  /// a full walk. A root that does not exist contributes a fixed marker.
  static String _stamp(List<String> roots) {
    final buffer = StringBuffer();
    for (final root in roots) {
      buffer.write(root);
      buffer.write('|');
      try {
        final dir = Directory(root);
        buffer.write(dir.existsSync() ? dir.statSync().modified.millisecondsSinceEpoch : -1);
      } catch (_) {
        buffer.write('?');
      }
      buffer.write(';');
    }
    return buffer.toString();
  }

  /// Drops the memoized folder walk; the next [wallpapers] reads the disk
  /// again. The settings page's explicit refresh calls this, and so does
  /// anything that just changed a library on disk.
  void forgetScan() {
    _scanned = null;
    _scannedStamp = null;
  }

  /// The wallpaper the config points at ([file], as stored in config.json),
  /// resolved to its project.
  static WallpaperEngineWallpaper? describe(String file) {
    final normalized = _normalize(file);
    var dir = File(normalized).parent;
    for (var depth = 0; depth < 4; depth++) {
      final project = File('${dir.path}\\project.json');
      if (project.existsSync()) {
        try {
          return _fromProject(
              jsonDecode(project.readAsStringSync()), dir.path, normalized);
        } catch (_) {
          // A broken project.json still leaves the plain file usable below.
        }
        break;
      }
      final up = dir.parent;
      if (up.path == dir.path) break;
      dir = up;
    }

    // No project metadata: usable only when the file itself is a picture or a
    // video (a local wallpaper dropped in as a bare file).
    final ext = _ext(normalized);
    if (_imageExts.contains(ext) || _videoExts.contains(ext)) {
      return WallpaperEngineWallpaper(
        title: _basename(normalized),
        type: _videoExts.contains(ext) ? 'video' : 'image',
        projectDir: dir.path,
        primaryFile: normalized,
      );
    }
    return null;
  }

  /// The wallpaper in [dir], or null when there is no project.json there.
  static WallpaperEngineWallpaper? _project(String dir) {
    final project = File('$dir\\project.json');
    if (!project.existsSync()) return null;
    try {
      return _fromProject(jsonDecode(project.readAsStringSync()), dir, null);
    } catch (_) {
      return null;
    }
  }

  /// Builds a wallpaper from project.json. [played] is the file Wallpaper
  /// Engine actually plays, when that is known (from config.json).
  static WallpaperEngineWallpaper? _fromProject(
      Object? json, String dir, String? played) {
    if (json is! Map) return null;
    final declared = json['file'];
    final declaredPath = declared is String && declared.isNotEmpty
        ? '${_normalize(dir)}\\${_normalize(declared)}'
        : null;
    final type = (json['type'] as String? ?? '').toLowerCase();
    // project.json's "file" can be a descriptor that is not on disk at all: a
    // scene names `scene.json`, and that file lives *inside* the sibling
    // `scene.pkg` — the package is what Wallpaper Engine plays. So the package
    // is a candidate in its own right, and the first file that really exists
    // wins.
    final candidates = <String>[
      ?played,
      ?declaredPath,
      if (type == 'scene') '${_normalize(dir)}\\scene.pkg',
    ];
    if (candidates.isEmpty) return null;
    final primary = candidates.firstWhere(
      (path) => File(path).existsSync(),
      orElse: () => candidates.first,
    );
    final title = json['title'];
    return WallpaperEngineWallpaper(
      title: title is String && title.trim().isNotEmpty
          ? title.trim()
          : _basename(dir),
      type: type,
      projectDir: dir,
      primaryFile: primary,
      previewPath: _preview(json, dir),
    );
  }

  /// The project's preview picture: the declared name first, then the
  /// conventional one. Authors ship jpg, png or an animated gif (which
  /// Flutter plays back on its own).
  static String? _preview(Map<dynamic, dynamic> json, String dir) {
    final declared = json['preview'];
    if (declared is String && declared.isNotEmpty) {
      final path = '${_normalize(dir)}\\${_normalize(declared)}';
      if (File(path).existsSync()) return path;
    }
    for (final name in const [
      'preview.jpg', 'preview.png', 'preview.jpeg', 'preview.gif', 'preview.webp',
    ]) {
      final path = '$dir\\$name';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Picks the file to use as the app background for [wallpaper].
  ///
  /// Pictures are used as they are; videos get one real frame decoded at
  /// [boxWidth] × [boxHeight]; scenes get their own artwork pulled out of
  /// `scene.pkg` (usually the full-resolution backdrop, not the thumbnail).
  /// Web pages and applications can only be represented by the author's
  /// preview picture, because rendering those needs Wallpaper Engine itself.
  Future<WallpaperEngineStill?> resolveStill(
    WallpaperEngineWallpaper wallpaper, {
    required String cacheDir,
    required int boxWidth,
    required int boxHeight,
  }) async {
    if (wallpaper.isImage) {
      return WallpaperEngineStill(path: wallpaper.primaryFile, kind: 'image');
    }
    if (wallpaper.isVideo) {
      final video = wallpaper.videoFile;
      if (video != null) {
        // Decoding a frame and encoding a PNG costs hundreds of milliseconds
        // and a lot of memory; the file name carries the source and the box,
        // so switching away from a wallpaper and back reuses the one that is
        // already on disk.
        final out =
            '$cacheDir\\we-frame-${_stillKey(video, boxWidth, boxHeight)}.png';
        if (File(out).existsSync()) {
          return WallpaperEngineStill(path: out, kind: 'video-frame');
        }
        final rendered = await Isolate.run(() => renderVideoStill(
              video,
              out,
              boxWidth: boxWidth,
              boxHeight: boxHeight,
            ));
        if (rendered != null) {
          return WallpaperEngineStill(path: rendered, kind: 'video-frame');
        }
      }
    }
    if (wallpaper.type == 'scene') {
      final pkg = wallpaper.primaryFile.toLowerCase().endsWith('.pkg')
          ? wallpaper.primaryFile
          : null;
      if (pkg != null) {
        // Same idea: the extraction writes `we-scene-<key>.jpg` (or .png), so
        // a cached one is checked before the package is opened again — both
        // endings, because the payload decides which one is written.
        final base = '$cacheDir\\we-scene-${_stillKey(pkg, 0, 0)}';
        for (final ext in const ['.jpg', '.png']) {
          if (File('$base$ext').existsSync()) {
            return WallpaperEngineStill(path: '$base$ext', kind: 'scene-artwork');
          }
        }
        final artwork =
            await Isolate.run(() => extractSceneBackdrop(pkg, base));
        if (artwork != null) {
          return WallpaperEngineStill(path: artwork, kind: 'scene-artwork');
        }
      }
    }
    final preview = wallpaper.previewPath;
    if (preview != null) {
      return WallpaperEngineStill(path: preview, kind: 'preview');
    }
    return null;
  }

  /// A stable, file-name-safe key for one source at one output size. FNV-1a
  /// over the lower-cased path, so it survives restarts (unlike hashCode).
  static String _stillKey(String path, int width, int height) {
    var hash = 0xcbf29ce484222325;
    for (final code in '$width x $height|${path.toLowerCase()}'.codeUnits) {
      hash ^= code;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }
}
