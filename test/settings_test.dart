import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/data/app_database.dart';
import 'package:xgame_desktop/native/hwprobe_bindings.dart';
import 'package:xgame_desktop/state/app_power.dart';
import 'package:xgame_desktop/state/live_surfaces.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/state/settings_spec.dart';
import 'package:xgame_desktop/ui/settings_page.dart';
import 'package:xgame_desktop/ui/title_bar.dart';

void main() {
  late Directory dataDir;
  late File source;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_settings');
    source = File('${Directory.systemTemp.path}\\xg_wall_source.png')
      ..writeAsBytesSync(List<int>.filled(64, 7));
  });

  tearDown(() {
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
    try {
      source.deleteSync();
    } catch (_) {}
  });

  /// A provider over the temp data dir. It is released with the test, because a
  /// provider holds the profile database open and Windows will not let the
  /// directory go while it does.
  SettingsProvider tracked() {
    final settings = SettingsProvider(dataDir: dataDir);
    addTearDown(settings.dispose);
    return settings;
  }

  /// A fresh provider over the same data dir, as a restart would see it.
  Future<SettingsProvider> reloaded() async {
    final next = tracked();
    await next.load();
    return next;
  }

  Future<void> pumpPage(
    WidgetTester tester,
    SettingsProvider settings, {
    VoidCallback? onClose,
    String? Function()? pickImage,
  }) async {
    // These tests are about the manual wallpaper flow; keep the Wallpaper
    // Engine section off this machine's real installation.
    settings.wallpaperEngineLocator = () => null;
    // The real window is a large desktop surface; the default 800×600 test
    // view would push the lower sections out of the scroll view.
    tester.view.physicalSize = const Size(1500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(
            body: SettingsPage(
              onClose: onClose ?? () {},
              pickImage: pickImage,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Color scrimColor(WidgetTester tester) => tester
      .widget<ColoredBox>(find.byKey(const Key('backgroundScrim')))
      .color;

  test('设置背景会把图片复制进数据目录，清除时删掉副本', () async {
    final s = tracked();
    expect(s.hasBackground, isFalse);

    expect(s.setBackgroundFrom(source.path), isTrue);
    expect(s.hasBackground, isTrue);
    final copy = File(s.backgroundPath!);
    expect(copy.existsSync(), isTrue);
    expect(copy.parent.path, dataDir.path, reason: '副本必须留在数据目录里');
    expect(copy.readAsBytesSync(), source.readAsBytesSync());

    // The original goes away; the copy keeps working.
    source.deleteSync();
    expect(File(s.backgroundPath!).existsSync(), isTrue);

    s.clearBackground();
    expect(s.hasBackground, isFalse);
    expect(copy.existsSync(), isFalse);
  });

  test('换一张背景图会清掉旧的副本', () async {
    final s = tracked();
    s.setBackgroundFrom(source.path);
    final first = File(s.backgroundPath!);

    s.setBackgroundFrom(source.path);
    expect(File(s.backgroundPath!).existsSync(), isTrue);
    expect(first.path, isNot(s.backgroundPath));
    expect(first.existsSync(), isFalse, reason: '旧副本不该越攒越多');
  });

  test('背景与主题设置一起持久化，重启后恢复', () async {
    final s = tracked();
    s.setPalette(PaletteId.lava);
    expect(s.setBackgroundFrom(source.path), isTrue);
    s.setBackgroundDim(0.35);
    s.setBackgroundBlur(9);
    s.setBackgroundFit(BackgroundFit.tile);
    final path = s.backgroundPath;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    s.dispose();

    final next = await reloaded();
    expect(next.palette, PaletteId.lava);
    expect(next.backgroundPath, path);
    expect(next.backgroundDim, 0.35);
    expect(next.backgroundBlur, 9);
    expect(next.backgroundFit, BackgroundFit.tile);
    expect(next.hasBackground, isTrue);
  });

  test('数据目录里没有副本时，设置里的背景条目被忽略', () async {
    final s = tracked();
    s.setBackgroundFrom(source.path);
    File(s.backgroundPath!).deleteSync();
    s.dispose();

    final next = await reloaded();
    expect(next.hasBackground, isFalse, reason: '缺文件时退回纯主题色，而不是显示坏图');
  });

  test('开机自启动偏好持久化，重启后恢复', () async {
    final s = tracked();
    // With a data-dir override the machine is never touched; the preference
    // alone flips.
    expect(await s.setLaunchOnStartup(true), isTrue);
    s.dispose();

    final next = await reloaded();
    expect(next.launchOnStartup, isTrue);

    expect(await next.setLaunchOnStartup(false), isTrue);
    next.dispose();
    final again = await reloaded();
    expect(again.launchOnStartup, isFalse);
  });

  testWidgets('设置页三组设置齐全，未设置背景时给出提示且不能清除', (tester) async {
    final s = tracked();
    await pumpPage(tester, s);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('背景'), findsOneWidget);
    expect(find.text('主题颜色'), findsOneWidget);
    expect(find.text('通用'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('未设置背景图'), findsOneWidget);
    expect(find.text('选择图片'), findsOneWidget);

    // Nothing to clear yet: the button is inert, not hidden.
    await tester.tap(find.text('清除背景'));
    await tester.pumpAndSettle();
    expect(s.hasBackground, isFalse);
  });

  testWidgets('选择图片后预览换成该图，清除后回到提示', (tester) async {
    final s = tracked();
    await pumpPage(tester, s, pickImage: () => source.path);

    await tester.tap(find.text('选择图片'));
    await tester.pumpAndSettle();

    expect(s.hasBackground, isTrue);
    final image = tester.widget<Image>(find.byType(Image));
    // The decoder is asked for the window's width — a 4K wallpaper is decoded
    // down to it — so the file provider rides inside a ResizeImage.
    final provider = image.image;
    final file = provider is ResizeImage
        ? (provider.imageProvider as FileImage).file
        : (provider as FileImage).file;
    expect(file.path, s.backgroundPath);
    // The scrim is part of the preview, not just the window.
    expect(scrimColor(tester).a, closeTo(s.backgroundDim, 0.001));

    await tester.tap(find.text('清除背景'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.text('未设置背景图'), findsOneWidget);
  });

  testWidgets('拖动暗化滑块，遮罩透明度跟着走', (tester) async {
    final s = tracked();
    s.setBackgroundFrom(source.path);
    await pumpPage(tester, s);

    final rect = tester.getRect(find.byKey(const Key('backgroundDim')));
    await tester.tapAt(Offset(rect.left + rect.width * 0.7, rect.center.dy));
    await tester.pumpAndSettle();

    expect(s.backgroundDim, greaterThan(0.4));
    expect(scrimColor(tester).a, closeTo(s.backgroundDim, 0.02));

    // Let the debounced save fire so no timer outlives the test.
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('切换填充方式与主题色', (tester) async {
    final s = tracked();
    await pumpPage(tester, s);

    await tester.tap(find.text('平铺'));
    await tester.pumpAndSettle();
    expect(s.backgroundFit, BackgroundFit.tile);

    await tester.tap(find.text('熔岩橙'));
    await tester.pumpAndSettle();
    expect(s.palette, PaletteId.lava);
    expect(s.backgroundFit, BackgroundFit.tile, reason: '换主题不该动背景设置');
  });

  testWidgets('Esc 与关闭按钮都能退出设置页', (tester) async {
    var closed = 0;
    await pumpPage(tester, tracked(),
        onClose: () => closed++);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(closed, 1);

    await tester.tap(find.byKey(const Key('settingsClose')));
    await tester.pumpAndSettle();
    expect(closed, 2);
  });

  testWidgets('标题栏齿轮是设置入口，未接线时不显示', (tester) async {
    var taps = 0;
    final settings = tracked();
    Widget host(TitleBar bar) => ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: MaterialApp(
            theme: buildTheme(appPalettes.first),
            home: Scaffold(body: bar),
          ),
        );

    await tester.pumpWidget(host(TitleBar(onToggleSettings: () => taps++)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(taps, 1);

    await tester.pumpWidget(host(const TitleBar()));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
  });

  testWidgets('通用区的开机自启动开关随手柄遍历可达并生效', (tester) async {
    final s = tracked();
    await pumpPage(tester, s);

    final toggle = find.byKey(const Key('launchOnStartup'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(s.launchOnStartup, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(s.launchOnStartup, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(s.launchOnStartup, isFalse);
  });

  testWidgets('监控口径开关写入设置并持久化，重启后恢复', (tester) async {
    final s = tracked();
    await pumpPage(tester, s);

    // The monitoring section sits below the fold; bring it in before tapping.
    final toggle = find.byKey(const Key('usageTaskManagerMode'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(s.usageSensorMode, usageModeStandard);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(s.usageSensorMode, usageModeTaskManager);

    // A restart reads the switch back from disk. Real file I/O has to run
    // outside the fake async zone the widget test lives in.
    final next = tracked();
    await tester.runAsync(next.load);
    expect(next.usageSensorMode, usageModeTaskManager);
  });

  test('场景帧率持久化，非法值回到默认', () async {
    final s = tracked();
    s.setSceneFps(60);
    expect(s.sceneFps, 60);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    s.dispose();

    final next = await reloaded();
    expect(next.sceneFps, 60);
    next.dispose();

    // A stale or hand-edited row with a rate we do not offer falls back to the
    // default budget instead of riding it into the renderer.
    final db = AppDatabase.open(dataDir);
    db.configStore().write(Settings.sceneFps, 45);
    db.close();

    final stale = await reloaded();
    expect(stale.sceneFps, 30);
    stale.dispose();
  });

  test('低功耗档：自动跟随电池，帧率与模糊收到上限，选择能存回来', () async {
    // The verdict is process-global (AppPower); nothing else in this file may
    // inherit whatever this case leaves behind.
    addTearDown(() => AppPower.economy.value = false);

    final s = tracked()
      ..setSceneFps(60)
      ..setBackgroundBlur(16);

    // Nobody has said anything, and this machine is not a handheld: off.
    expect(s.lowPowerOn, isFalse);
    expect(s.effectiveSceneFps, 60);
    expect(s.effectiveBackgroundBlur, 16);
    expect(AppPower.economy.value, isFalse);

    // A battery is what "auto" waits for.
    s.setHandheld(true);
    expect(s.lowPowerOn, isTrue);
    expect(s.effectiveSceneFps, 15, reason: '场景壁纸收到低功耗上限');
    expect(s.effectiveBackgroundBlur, 8, reason: '整窗高斯收到低功耗上限');
    expect(AppPower.economy.value, isTrue,
        reason: '叶子控件读的就是这一个信号');

    // An explicit choice overrules the battery, in both directions.
    s.setLowPower(false);
    expect(s.lowPowerOn, isFalse);
    expect(s.effectiveSceneFps, 60);
    expect(s.effectiveBackgroundBlur, 16);
    expect(AppPower.economy.value, isFalse);

    s.setLowPower(true);
    expect(s.lowPowerOn, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect((await reloaded()).lowPower, isTrue, reason: '明确的选择要能存回来');

    // Back to auto, which is a value of its own rather than a missing key.
    s.setLowPower(null);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    s.dispose();
    final next = await reloaded();
    expect(next.lowPower, isNull);
    next.setHandheld(false);
    expect(next.lowPowerOn, isFalse);
  });

  testWidgets('场景壁纸的帧率档位只在场景时出现，点选即生效', (tester) async {
    LiveSurfaces.scene = true;
    addTearDown(() => LiveSurfaces.scene = false);

    final s = tracked();
    await pumpPage(tester, s);
    expect(find.text('帧率'), findsNothing,
        reason: '图片/视频/网页不按固定帧率画,不该出现这个档位');

    // 带着场景壁纸进来(直接赋值不通知,重挂一次页面等同重启后读到的状态)。
    s.backgroundPath = r'E:\workshop\100\scene.pkg';
    s.backgroundSource = BackgroundSource.scene;
    await pumpPage(tester, s);
    expect(find.text('帧率'), findsOneWidget);

    await tester.ensureVisible(find.text('帧率'));
    await tester.tap(find.text('15'));
    await tester.pumpAndSettle();
    expect(s.sceneFps, 15);

    await tester.tap(find.text('60'));
    await tester.pumpAndSettle();
    expect(s.sceneFps, 60);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('模糊滑块拖动过程中不改背景，松手才应用', (tester) async {
    final s = tracked();
    s.setBackgroundFrom(source.path);
    await pumpPage(tester, s);
    expect(s.backgroundBlur, 0);

    final rect = tester.getRect(find.byKey(const Key('backgroundBlur')));
    final gesture = await tester.startGesture(rect.center);
    await tester.pump();
    await gesture.moveBy(Offset(rect.width * 0.5, 0));
    await tester.pump();
    await gesture.moveBy(Offset(rect.width * 0.25, 0));
    await tester.pump();
    // The thumb and the readout follow, the picture does not: every commit
    // mid-drag would re-rasterize the full-window blur per pointer move.
    expect(s.backgroundBlur, 0);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(s.backgroundBlur, greaterThan(0));
    expect(scrimColor(tester).a, closeTo(s.backgroundDim, 0.02),
        reason: '暗化不受影响,仍然实时跟随');

    // Let the debounced save fire so no timer outlives the test.
    await tester.pump(const Duration(milliseconds: 300));
  });
}
