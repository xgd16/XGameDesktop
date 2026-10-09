import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/state/wallpaper_server.dart';

/// The loopback server that feeds the in-app browser: it hands a scene page the
/// package and project file it asks for, plus the renderer itself, and it hosts
/// a web wallpaper's own folder so the page runs with a real origin instead of
/// as an opaque `file://` document. It reads nothing but the folders registered
/// for what is on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory scene;
  late Directory web;
  late Directory assets;
  late WallpaperServer server;
  late HttpClient client;

  setUp(() async {
    // flutter_test installs a mock HttpClient that answers every request with
    // 400; this test needs a real socket on the loopback interface.
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);

    scene = Directory.systemTemp.createTempSync('xg_scene_server');
    File('${scene.path}${Platform.pathSeparator}scene.pkg')
        .writeAsBytesSync(List.generate(64, (i) => i));
    File('${scene.path}${Platform.pathSeparator}project.json')
        .writeAsStringSync('{"type":"scene","title":"Into The Woods"}');
    File('${scene.path}${Platform.pathSeparator}preview.jpg')
        .writeAsBytesSync([0xFF, 0xD8, 0xFF]);

    web = Directory.systemTemp.createTempSync('xg_web_server');
    File('${web.path}${Platform.pathSeparator}index.html').writeAsStringSync(
        '<script type="module" crossorigin src="assets/index.js"></script>');
    final webAssets =
        Directory('${web.path}${Platform.pathSeparator}assets')..createSync();
    File('${webAssets.path}${Platform.pathSeparator}index.js')
        .writeAsStringSync('export const a = 1;');
    File('${webAssets.path}${Platform.pathSeparator}index.css')
        .writeAsStringSync('body { background: #000; }');

    assets = Directory.systemTemp.createTempSync('xg_scene_assets');
    final snow = Directory(
        '${assets.path}${Platform.pathSeparator}materials'
        '${Platform.pathSeparator}particle${Platform.pathSeparator}nature')
      ..createSync(recursive: true);
    File('${snow.path}${Platform.pathSeparator}snow.tex')
        .writeAsBytesSync([1, 2, 3, 4]);
    WallpaperServer.assetsDirOverride = assets;

    server = await WallpaperServer.start();
    client = HttpClient();
  });

  tearDown(() async {
    WallpaperServer.assetsDirOverride = null;
    client.close(force: true);
    await server.stop();
    for (final dir in [scene, web, assets]) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<HttpClientResponse> get(String path) async =>
      (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}$path')))
          .close();

  Future<String> body(HttpClientResponse response) async =>
      utf8.decode(await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b)));

  test('页面拿得到 pkg、project.json 和渲染器本身', () async {
    final page = Uri.parse(server.registerScene(
        '${scene.path}${Platform.pathSeparator}scene.pkg'));
    expect(page.host, '127.0.0.1');
    expect(page.query, 'localAssets=1', reason: '机器上装了 WE，顺带指过去');

    final html = await get(page.path);
    expect(html.statusCode, 200);
    final text = await body(html);
    expect(text, contains('/lib/webwallgl.min.mjs'));
    expect(text, contains('httpSource(location.pathname)'));

    final pkg = await get('${page.path}scene.pkg');
    expect(pkg.statusCode, 200);
    expect(pkg.headers.contentType?.mimeType, 'application/octet-stream');
    final bytes = await pkg.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    expect(bytes, List.generate(64, (i) => i));

    final project = await get('${page.path}project.json');
    expect(project.statusCode, 200);
    expect(await body(project), contains('Into The Woods'));

    final renderer = await get('/lib/webwallgl.min.mjs');
    expect(renderer.statusCode, 200);
    expect(renderer.headers.contentType?.mimeType, 'text/javascript');
    final source = await body(renderer);
    expect(source.length, greaterThan(100000), reason: '整个渲染器都在里面');
    expect(source, contains('WEBGL2_UNAVAILABLE'));
  });

  test('网页壁纸整页连资源一起托管，类型按浏览器要的给', () async {
    final page = Uri.parse(
        server.registerPage('${web.path}${Platform.pathSeparator}index.html'));
    expect(page.host, '127.0.0.1');
    expect(page.query, isEmpty, reason: '网页壁纸用不着材料库');
    final root = '/${page.pathSegments.take(2).join('/')}';

    final html = await get(page.path);
    expect(html.statusCode, 200);
    expect(html.headers.contentType?.mimeType, 'text/html');
    expect(await body(html), contains('type="module"'));

    // The page's own neighbours — this is what `file://` refuses to hand a
    // module script.
    final js = await get('$root/assets/index.js');
    expect(js.statusCode, 200);
    expect(js.headers.contentType?.mimeType, 'text/javascript');
    expect(await body(js), contains('export const a'));

    final css = await get('$root/assets/index.css');
    expect(css.statusCode, 200);
    expect(css.headers.contentType?.mimeType, 'text/css');

    final page2 = Uri.parse(
        server.registerPage('${web.path}${Platform.pathSeparator}index.html'));
    expect(page2.path, page.path, reason: '同一个目录始终是同一个地址');
  });

  test('没注册过的目录和越界的路径都读不到', () async {
    final page = Uri.parse(server.registerScene(
        '${scene.path}${Platform.pathSeparator}scene.pkg'));
    final webPage = Uri.parse(
        server.registerPage('${web.path}${Platform.pathSeparator}index.html'));
    final webRoot = '/${webPage.pathSegments.take(2).join('/')}';

    final stranger =
        File('${scene.parent.path}${Platform.pathSeparator}xg_scene_secret.txt')
          ..writeAsStringSync('secret');
    addTearDown(() {
      try {
        stranger.deleteSync();
      } catch (_) {}
    });

    for (final path in [
      '/scene/other/scene.pkg',
      '/web/other/index.html',
      '/web/${webPage.pathSegments[1]}',
      '${page.path}%2e%2e%2fxg_scene_secret.txt',
      '${page.path}..%2fxg_scene_secret.txt',
      '${page.path}nope.txt',
      '$webRoot/%2e%2e%2fxg_scene_secret.txt',
      '/scene/${page.pathSegments[1]}/C:%5CWindows%5Cwin.ini',
    ]) {
      final response = await get(path);
      expect(response.statusCode, 404, reason: path);
      await response.drain<void>();
    }
  });

  test('WE 的材料库按渲染器要的形状给出去，没有 WE 时明说没有', () async {
    final info = await get('/api/local-assets');
    expect(await body(info), contains('"ok":true'));
    expect(await body(await get('/api/local-assets')), contains('"id":"we"'));

    final index = await body(await get('/api/local-assets/we/materials/index.json'));
    expect(jsonDecode(index), {
      'names': ['particle/nature/snow'],
    });

    final tex = await get('/api/local-assets/we/materials/particle/nature/snow.tex');
    expect(tex.statusCode, 200);
    expect(await tex.fold<List<int>>(<int>[], (a, b) => a..addAll(b)), [1, 2, 3, 4]);

    WallpaperServer.assetsDirOverride = Directory('${assets.path}\\missing');
    final none = await get('/api/local-assets');
    expect(await body(none), '{"ok":false}');
    final noQuery = Uri.parse(server.registerScene(
        '${scene.path}${Platform.pathSeparator}preview.jpg'));
    expect(noQuery.query, isEmpty, reason: '没有材料库就不去要');
  });
}
