import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/native/wallpaper_engine.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/state/live_surfaces.dart';
import 'package:xgame_desktop/state/wallpaper_gate.dart';
import 'package:xgame_desktop/ui/web_background.dart';
import 'package:xgame_desktop/ui/background_layer.dart';
import 'package:xgame_desktop/ui/scene_background.dart';
import 'package:xgame_desktop/ui/settings_page.dart';
import 'package:xgame_desktop/ui/video_background.dart';

import 'we_fixture.dart';

/// The Wallpaper Engine picker: list what WE has, choose one for the app
/// background. All of it is file-based, so WE never has to be running.
void main() {
  late SteamTree tree;
  late Directory dataDir;
  late SettingsProvider settings;
  late Directory scene;


  /// A provider over the temp data dir, released with the test. It holds the
  /// profile database open, and Windows will not delete the directory until it
  /// lets go.
  SettingsProvider tracked() {
    final provider = SettingsProvider(dataDir: dataDir);
    addTearDown(provider.dispose);
    return provider;
  }

  setUp(() {
    tree = SteamTree();
    dataDir = Directory.systemTemp.createTempSync('xg_we_settings');
    scene = tree.project('100',
        type: 'scene',
        file: 'scene.json',
        createPrimary: false,
        title: 'Into The Woods',
        extraFiles: {'scene.pkg': 'x'});
    tree.project('200', type: 'web', file: 'index.html', title: 'CodeTime');
    tree.select('${scene.path}\\scene.pkg');
    addTearDown(() {
      tree.dispose();
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    // Adopting a live wallpaper starts the wallpaper gate's fullscreen probe
    // mid-test; take it back down so no timer outlives the test.
    addTearDown(() {
      WallpaperGate.stop();
      WallpaperGate.probeOverride = null;
    });
    // Last registered, first released: the provider lets go of the profile
    // database before the directory above is deleted.
    settings = tracked()..wallpaperEngineLocator = () => tree.library;
  });

  test('刷新列出所有壁纸，WE 当前那张排在最前', () {
    settings.refreshWallpaperEngine();
    expect(settings.weFound, isTrue);
    expect(settings.weWallpapers.length, 2);
    expect(settings.weWallpapers.first.title, 'Into The Woods',
        reason: '当前壁纸置顶');
    expect(settings.weCurrentFile, '${scene.path}\\scene.pkg');
    expect(settings.weWallpapers.map((w) => w.title),
        containsAll(['Into The Woods', 'CodeTime']));
  });

  test('没有安装 Wallpaper Engine：列表为空，其他功能不受影响', () {
    settings.wallpaperEngineLocator = () => null;
    settings.refreshWallpaperEngine();
    expect(settings.weFound, isFalse);
    expect(settings.weWallpapers, isEmpty);
    expect(settings.weCurrentFile, isNull);

    // Manual picking still works — WE is an extra, not a dependency.
    final manual = File('${dataDir.path}\\manual.png')
      ..writeAsStringSync('mine');
    expect(settings.setBackgroundFrom(manual.path), isTrue);
    expect(settings.hasBackground, isTrue);
    expect(settings.backgroundIsWallpaperEngine, isFalse);
  });

  test('选用场景壁纸：复制作者预览图并记下来源', () async {
    settings.refreshWallpaperEngine();
    final wallpaper = settings.weWallpapers
        .firstWhere((w) => w.title == 'Into The Woods');

    expect(await settings.useWallpaperEngine(wallpaper), isTrue);
    expect(settings.hasBackground, isTrue);
    expect(settings.backgroundIsWallpaperEngine, isTrue);
    expect(settings.backgroundLabel, 'Into The Woods · 场景');
    final copy = File(settings.backgroundPath!);
    expect(copy.parent.path, dataDir.path);
    expect(copy.readAsStringSync(), 'preview-of-100');

    // Choosing the same one again is a no-op, not another copy.
    final path = settings.backgroundPath;
    expect(await settings.useWallpaperEngine(wallpaper), isTrue);
    expect(settings.backgroundPath, path);

    // Switching to the other wallpaper replaces the copy.
    final other =
        settings.weWallpapers.firstWhere((w) => w.title == 'CodeTime');
    expect(await settings.useWallpaperEngine(other), isTrue);
    expect(settings.backgroundLabel, 'CodeTime · 网页');
    expect(settings.backgroundPath, isNot(path));
    expect(File(settings.backgroundPath!).readAsStringSync(), 'preview-of-200');
    expect(File(path!).existsSync(), isFalse, reason: '旧副本不留下');
  });

  test('选用视频壁纸：可以播放时直接引用原文件，既不复制也不提帧', () async {
    LiveSurfaces.video = true;
    addTearDown(() => LiveSurfaces.video = false);
    final video = tree.project('300',
        type: 'video', file: 'clip.mp4', preview: 'preview.gif',
        title: 'Stars');
    final wallpaper =
        WallpaperEngineLibrary.describe('${video.path}\\clip.mp4')!;

    expect(await settings.useWallpaperEngine(wallpaper), isTrue);
    expect(settings.backgroundSource, BackgroundSource.video);
    expect(settings.backgroundPath, '${video.path}\\clip.mp4',
        reason: '直接播原文件');
    expect(settings.backgroundLabel, 'Stars · 视频');
    expect(
        dataDir
            .listSync()
            .where((e) => e.uri.pathSegments.last.startsWith('background')),
        isEmpty,
        reason: '视频太大，不往数据目录复制');

    // Restart: the same file is picked up again.
    settings.dispose();
    final next = tracked()
      ..wallpaperEngineLocator = () => tree.library;
    await next.load();
    expect(next.backgroundSource, BackgroundSource.video);
    expect(next.backgroundPath, '${video.path}\\clip.mp4');

    // Choosing a picture afterwards drops the video flag.
    final manual = File('${dataDir.path}\\manual.png')
      ..writeAsStringSync('mine');
    expect(next.setBackgroundFrom(manual.path), isTrue);
    expect(next.backgroundSource, BackgroundSource.image);
  });

  test('视频壁纸在无法播放时（没有 libmpv）退到预览图', () async {
    expect(LiveSurfaces.video, isFalse, reason: '测试环境默认不播放视频');
    final video = tree.project('300',
        type: 'video', file: 'clip.mp4', preview: 'preview.gif',
        title: 'Stars');
    final wallpaper =
        WallpaperEngineLibrary.describe('${video.path}\\clip.mp4')!;
    // A fake .mp4 has no decodable frame either: the fallback must kick in.
    expect(await settings.useWallpaperEngine(wallpaper), isTrue);
    expect(settings.backgroundSource, BackgroundSource.image);
    expect(settings.backgroundLabel, 'Stars · 视频');
    expect(File(settings.backgroundPath!).readAsStringSync(), 'preview-of-300');
  });

  test('选用网页壁纸：直接跑作者的页面，不复制，重启后仍在', () async {
    LiveSurfaces.web = true;
    addTearDown(() => LiveSurfaces.web = false);
    final web = tree.project('500',
        type: 'web', file: 'index.html', title: 'Solar System');
    final wallpaper =
        WallpaperEngineLibrary.describe('${web.path}\\index.html')!;

    expect(await settings.useWallpaperEngine(wallpaper), isTrue);
    expect(settings.backgroundSource, BackgroundSource.web);
    expect(settings.backgroundPath, '${web.path}\\index.html',
        reason: '页面要连同目录里的资源一起跑，不能只复制一个文件');
    expect(settings.backgroundLabel, 'Solar System · 网页');
    expect(
        dataDir
            .listSync()
            .where((e) => e.uri.pathSegments.last.startsWith('background')),
        isEmpty);

    settings.dispose();
    final next = tracked()
      ..wallpaperEngineLocator = () => tree.library;
    await next.load();
    expect(next.backgroundSource, BackgroundSource.web);
    expect(next.backgroundPath, '${web.path}\\index.html');
  });

  test('场景壁纸认的是包，哪怕 WE 当前应用的正是别的壁纸', () {
    // project.json 写的是 scene.json（打包在 scene.pkg 里），WE 没把这张设为
    // 当前壁纸时，列表里那条也得指到真正能播的包上。
    tree.select('${tree.contentDir.path}\\200\\index.html');
    settings.refreshWallpaperEngine();
    final wallpaper = settings.weWallpapers
        .firstWhere((w) => w.title == 'Into The Woods');
    expect(wallpaper.primaryFile, '${scene.path}\\scene.pkg');
    expect(wallpaper.scenePkg, '${scene.path}\\scene.pkg');
    expect(wallpaper.isScene, isTrue);
  });

  test('选用场景壁纸：直接读原包实时渲染，不复制，重启后仍在', () async {
    LiveSurfaces.scene = true;
    addTearDown(() => LiveSurfaces.scene = false);
    // Not the wallpaper WE applies: the pick must still resolve to the package.
    tree.select('${tree.contentDir.path}\\200\\index.html');
    settings.refreshWallpaperEngine();
    final wallpaper = settings.weWallpapers
        .firstWhere((w) => w.title == 'Into The Woods');

    expect(await settings.useWallpaperEngine(wallpaper), isTrue);
    expect(settings.backgroundSource, BackgroundSource.scene);
    expect(settings.backgroundPath, '${scene.path}\\scene.pkg',
        reason: '渲染器直接读原包，连同目录里的资源');
    expect(settings.backgroundLabel, 'Into The Woods · 场景');
    expect(
        dataDir
            .listSync()
            .where((e) => e.uri.pathSegments.last.startsWith('background')),
        isEmpty);

    settings.dispose();
    final next = tracked()
      ..wallpaperEngineLocator = () => tree.library;
    await next.load();
    expect(next.backgroundSource, BackgroundSource.scene);
    expect(next.backgroundPath, '${scene.path}\\scene.pkg');
  });

  test('来源与背景一起持久化，重启后仍在', () async {
    settings.refreshWallpaperEngine();
    await settings.useWallpaperEngine(
        settings.weWallpapers.firstWhere((w) => w.title == 'CodeTime'));
    final path = settings.backgroundPath;
    settings.dispose();

    final next = tracked()
      ..wallpaperEngineLocator = () => tree.library;
    await next.load();
    expect(next.backgroundPath, path);
    expect(next.backgroundIsWallpaperEngine, isTrue);
    expect(next.backgroundLabel, 'CodeTime · 网页');
  });

  test('手动选图或清除背景都会洗掉 Wallpaper Engine 来源', () async {
    settings.refreshWallpaperEngine();
    await settings.useWallpaperEngine(settings.weWallpapers.first);
    expect(settings.backgroundIsWallpaperEngine, isTrue);

    final manual = File('${dataDir.path}\\manual.png')
      ..writeAsStringSync('mine');
    expect(settings.setBackgroundFrom(manual.path), isTrue);
    expect(settings.backgroundIsWallpaperEngine, isFalse);
    expect(settings.backgroundLabel, isNull);

    settings.clearBackground();
    expect(settings.hasBackground, isFalse);
    expect(settings.backgroundLabel, isNull);
  });

  testWidgets('设置页列出壁纸，点一行就用它作背景', (tester) async {
    tester.view.physicalSize = const Size(1500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(body: SettingsPage(onClose: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Wallpaper Engine'), findsOneWidget);
    expect(find.text('2 张'), findsOneWidget);
    expect(find.text('Into The Woods'), findsOneWidget);
    expect(find.text('CodeTime'), findsOneWidget);
    expect(find.text('WE 当前'), findsOneWidget, reason: '标记 WE 当前使用的那张');

    await tester.tap(find.text('CodeTime'));
    await tester.pumpAndSettle();
    expect(settings.backgroundLabel, 'CodeTime · 网页');
    expect(find.text('使用中'), findsOneWidget);
    expect(find.text('已使用「CodeTime」'), findsOneWidget);

    // Let the toast's timer run out so nothing is pending at the end.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('没装 Wallpaper Engine 时说明情况，手动入口照常可用', (tester) async {
    settings.wallpaperEngineLocator = () => null;
    tester.view.physicalSize = const Size(1500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(body: SettingsPage(onClose: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未检测到 Wallpaper Engine，用上面的按钮也能选图片。'),
        findsOneWidget);
    expect(find.text('选择图片'), findsOneWidget);
    expect(find.byKey(const Key('weRefresh')), findsOneWidget);
  });

  testWidgets('视频背景交给播放组件，换成图片后回到图片', (tester) async {
    LiveSurfaces.video = true;
    VideoBackground.builderOverride = (widget) => Text('surface:${widget.path}');
    addTearDown(() {
      LiveSurfaces.video = false;
      VideoBackground.builderOverride = null;
    });
    final video = tree.project('400',
        type: 'video', file: 'clip.mp4', title: 'Stars');
    final wallpaper =
        WallpaperEngineLibrary.describe('${video.path}\\clip.mp4')!;
    expect(await settings.useWallpaperEngine(wallpaper), isTrue);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: const Scaffold(body: AppBackground()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('surface:${video.path}\\clip.mp4'), findsOneWidget);

    final manual = File('${dataDir.path}\\manual.png')
      ..writeAsStringSync('mine');
    settings.setBackgroundFrom(manual.path);
    await tester.pumpAndSettle();
    expect(find.textContaining('surface:'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('网页背景交给内置浏览器，视频不会凑热闹', (tester) async {
    LiveSurfaces.web = true;
    WebBackground.builderOverride = (widget) => Text('page:${widget.path}');
    VideoBackground.builderOverride = (widget) => Text('surface:${widget.path}');
    addTearDown(() {
      LiveSurfaces.web = false;
      LiveSurfaces.video = false;
      WebBackground.builderOverride = null;
      VideoBackground.builderOverride = null;
    });
    final web = tree.project('500',
        type: 'web', file: 'index.html', title: 'Solar System');
    expect(
        await settings.useWallpaperEngine(
            WallpaperEngineLibrary.describe('${web.path}\\index.html')!),
        isTrue);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: const Scaffold(body: AppBackground()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('page:${web.path}\\index.html'), findsOneWidget);
    expect(find.textContaining('surface:'), findsNothing);
  });

  testWidgets('场景背景交给内置渲染器，设置页的小预览只要静态图', (tester) async {
    LiveSurfaces.scene = true;
    SceneBackground.builderOverride =
        (widget) => Text('scene:${widget.pkgPath}:${widget.posterOnly}');
    addTearDown(() {
      LiveSurfaces.scene = false;
      SceneBackground.builderOverride = null;
    });
    final pkg = '${scene.path}\\scene.pkg';
    expect(
        await settings.useWallpaperEngine(WallpaperEngineLibrary.describe(pkg)!),
        isTrue);

    // The window: the live renderer.
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: const Scaffold(body: AppBackground()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('scene:$pkg:false'), findsOneWidget);

    // The settings card: a still, so a 16:9 thumbnail does not cost a second
    // renderer.
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: const Scaffold(
              body: SizedBox(width: 320, child: AppBackground(sceneStill: true))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('scene:$pkg:true'), findsOneWidget);
  });
}
