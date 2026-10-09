import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/state/apps_provider.dart';
import 'package:xgame_desktop/state/background_glass.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/ui/app_card.dart';
import 'package:xgame_desktop/ui/apps_pane.dart';
import 'package:xgame_desktop/ui/context_menu.dart';
import 'package:xgame_desktop/ui/widgets.dart';

/// 壁纸铺满整个窗口，压在上面的面板一旦用不透明底色，就等于把用户挑的
/// 壁纸盖掉一块。这些面板都应当是一层毛玻璃：背后有模糊，填充是半透明的。
///
/// 没有壁纸时反过来：面板背后只有纯色的主题底，模糊前后是同一批像素，
/// 每帧的回读与高斯就纯属浪费——毛玻璃降级成半透明填充，不挂
/// BackdropFilter。
///
/// 静态壁纸有第三档：背景层把整幅图连同暗化糊一份存起来（BackgroundGlass），
/// 桌面上的面板取自己那一块，每帧只花一次纹理采样——所以那些面板这时既不
/// 挂 BackdropFilter，也照样是毛玻璃。
void main() {
  late AppsProvider provider;
  late Directory dataDir;

  /// 烘好的模糊副本，供面板取样。
  Future<void> publishGlass(WidgetTester tester, {required double sigma}) async {
    final image =
        await tester.runAsync(() => createTestImage(width: 8, height: 8));
    addTearDown(BackgroundGlass.clear);
    BackgroundGlass.publish(GlassBackdrop(
      image: image!,
      pixelsPerLogical: 0.5,
      sigma: sigma,
    ));
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_frost');
    provider = AppsProvider(dataDir: dataDir, launcher: (_) => true)
      ..apps = [
        AppEntry(
          name: 'Steam',
          path: r'C:\Start Menu\Steam.lnk',
          hasDesktop: true,
        ),
      ]
      ..status = AppsStatus.ready;
  });

  tearDown(() {
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A provider over the temp data dir, released with the test. It holds the
  /// profile database open, and Windows will not delete the directory until it
  /// lets go.
  SettingsProvider tracked() {
    final settings = SettingsProvider(dataDir: dataDir);
    addTearDown(settings.dispose);
    return settings;
  }

  Future<void> pumpPane(WidgetTester tester, {bool wallpaper = true}) async {
    final settings = tracked()
      ..backgroundPath = wallpaper ? r'C:\wallpapers\scene.jpg' : null;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppsProvider>.value(
        value: provider,
        child: ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: MaterialApp(
            theme: buildTheme(appPalettes.first),
            home: const Scaffold(body: AppsPane()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The fill painted inside a frost must be see-through, or the blur behind
  /// it would never show.
  void expectTranslucentFill(WidgetTester tester, Finder within) {
    final box = tester.widget<DecoratedBox>(
      find.descendant(of: within, matching: find.byType(DecoratedBox)).first,
    );
    final color = (box.decoration as BoxDecoration).color!;
    expect(color.a, lessThan(1.0));
    expect(color.a, greaterThan(0.3));
  }

  testWidgets('搜索框与推荐/桌面切换是毛玻璃，壁纸能透出来', (tester) async {
    await pumpPane(tester);

    final frosts = find.byType(Frosted);
    expect(frosts, findsNWidgets(2), reason: '搜索框和视图切换各一层');
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    expectTranslucentFill(tester, frosts.at(0));
    expectTranslucentFill(tester, frosts.at(1));
  });

  testWidgets('没有壁纸时降级成半透明填充，不挂 BackdropFilter', (tester) async {
    await pumpPane(tester, wallpaper: false);

    // 面板还在——填充仍然是这块 UI 的样子——但背后只有纯色的主题底，
    // 模糊换不来一个像素的差别，每帧的回读不该付。
    final frosts = find.byType(Frosted);
    expect(frosts, findsNWidgets(2), reason: '搜索框和视图切换各一层');
    expect(find.byType(BackdropFilter), findsNothing);
    expectTranslucentFill(tester, frosts.at(0));
    expectTranslucentFill(tester, frosts.at(1));
  });

  testWidgets('鼠标停在应用磁贴上时出现高亮层，不做背景回读，移开就收掉', (tester) async {
    await pumpPane(tester);
    await tester.tap(find.text('桌面 1'));
    await tester.pumpAndSettle();

    Finder tileFrost() => find.descendant(
        of: find.byType(AppCard), matching: find.byType(Frosted));
    expect(tileFrost(), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(AppCard)));
    await tester.pumpAndSettle();

    expect(tileFrost(), findsOneWidget);
    expectTranslucentFill(tester, tileFrost());
    // 模糊留给手柄/键盘落上去的焦点；鼠标只是路过，停留多久都不做回读。
    expect(
        find.descendant(
            of: tileFrost(), matching: find.byType(BackdropFilter)),
        findsNothing);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(tileFrost(), findsNothing,
        reason: '静止的磁贴不该每帧回读一次背景');
  });

  testWidgets('右键菜单是浮在壁纸上的毛玻璃', (tester) async {
    await pumpPane(tester);
    await tester.tap(find.text('桌面 1'));
    await tester.pumpAndSettle();

    await tester.tapAt(tester.getCenter(find.byType(AppCard)),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    final panel = find.byKey(contextMenuKey);
    expect(panel, findsOneWidget);
    expect(
      find.ancestor(of: panel, matching: find.byType(Frosted)),
      findsOneWidget,
    );
    expectTranslucentFill(tester, panel);

    // The blur and the shadow both hang off the panel: the shadow outside the
    // clip, so it survives the rounded corners.
    final frost = find.ancestor(of: panel, matching: find.byType(Frosted));
    expect(find.descendant(of: frost, matching: find.byType(BackdropFilter)),
        findsOneWidget);
    expect(find.descendant(of: frost, matching: find.byType(ClipRRect)),
        findsOneWidget);
  });

  /// 静态壁纸的糊一次就已经存在：桌面上的面板该取样，而不是每帧再回读一次。
  testWidgets('壁纸糊好之后，桌面上的面板取样，不再挂 BackdropFilter', (tester) async {
    await publishGlass(tester, sigma: BackgroundGlass.frostSigma);
    await pumpPane(tester);

    expect(find.byType(WallpaperSample), findsNWidgets(2),
        reason: '搜索框和视图切换各取一份自己的裁切');
    expect(find.byType(BackdropFilter), findsNothing);
    expectTranslucentFill(tester, find.byType(Frosted).at(0));
    expectTranslucentFill(tester, find.byType(Frosted).at(1));
  });

  /// 烘出来的糊只配给同样模糊度的面板用：对不上就老实回读，否则panel之间的
  /// 玻璃会一块深一块浅。
  testWidgets('烘好的模糊和面板要的不一致时，仍然实时回读', (tester) async {
    await publishGlass(tester, sigma: 22);
    await pumpPane(tester);

    expect(find.byType(WallpaperSample), findsNothing);
    expect(find.byType(BackdropFilter), findsNWidgets(2));
  });

  /// 浮在网格上的玻璃背后有应用磁贴，取样壁纸会把它们一起抹掉——那类面板
  /// 永远回读，哪怕桌面壁纸已经烘好。
  testWidgets('浮在网格上的玻璃不取样壁纸', (tester) async {
    await publishGlass(tester, sigma: BackgroundGlass.frostSigma);
    await pumpPane(tester);
    await tester.tap(find.text('桌面 1'));
    await tester.pumpAndSettle();

    await tester.tapAt(tester.getCenter(find.byType(AppCard)),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    final frost = find.ancestor(
        of: find.byKey(contextMenuKey), matching: find.byType(Frosted));
    expect(find.descendant(of: frost, matching: find.byType(BackdropFilter)),
        findsOneWidget);
    expect(find.descendant(of: frost, matching: find.byType(WallpaperSample)),
        findsNothing);
  });
}
