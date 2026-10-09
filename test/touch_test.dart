import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/native/window_shell.dart';
import 'package:xgame_desktop/state/apps_provider.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/ui/app_card.dart';
import 'package:xgame_desktop/ui/apps_pane.dart';
import 'package:xgame_desktop/ui/context_menu.dart';
import 'package:xgame_desktop/ui/keyboard_overlay.dart';
import 'package:xgame_desktop/ui/title_bar.dart';

/// 触屏适配：手指够得着的命中区、长按当右键、屏幕键盘进得去。
void main() {
  late Directory dataDir;
  late AppsProvider provider;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_touch');
    provider = AppsProvider(dataDir: dataDir, launcher: (_) => true)
      ..apps = [
        AppEntry(
          name: 'Steam',
          path: r'C:\Start Menu\Steam.lnk',
          hasDesktop: true,
        ),
      ]
      ..view = AppsView.desktop
      ..status = AppsStatus.ready;
  });

  tearDown(() {
    WindowShell.debugTouchOverride = null;
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

  Future<void> pumpPane(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppsProvider>.value(
        value: provider,
        // 毛玻璃会问设置“背后有没有壁纸”；这里没有壁纸，玻璃照规矩
        // 降级成半透明填充。
        child: ChangeNotifierProvider<SettingsProvider>.value(
          value: tracked(),
          child: MaterialApp(
            theme: buildTheme(appPalettes.first),
            home: const Scaffold(body: AppsPane()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: tracked()
          ..wallpaperEngineLocator = () => null,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(
            body: TitleBar(onImmersive: () {}, onToggleSettings: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('触屏上标题栏按钮的命中区放大到手指大小', (tester) async {
    WindowShell.debugTouchOverride = true;
    await pumpBar(tester);
    final touch = tester.getSize(find.byTooltip('设置'));
    expect(touch.height, greaterThanOrEqualTo(44));
    expect(touch.width, greaterThanOrEqualTo(44));

    // 鼠标机器上还是原来那 32 px 的按钮：放大的是命中区，不是外观。
    WindowShell.debugTouchOverride = false;
    await pumpBar(tester);
    expect(tester.getSize(find.byTooltip('设置')).height, lessThan(44));
  });

  testWidgets('触屏：长按磁贴等于右键，弹出同一个菜单', (tester) async {
    WindowShell.debugTouchOverride = true;
    await pumpPane(tester);

    await tester.longPress(find.byType(AppCard).first);
    await tester.pumpAndSettle();
    expect(find.byKey(contextMenuKey), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byKey(contextMenuKey), findsNothing);
  });

  testWidgets('鼠标长按不该弹菜单，右键才是它的入口', (tester) async {
    await pumpPane(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.down(tester.getCenter(find.byType(AppCard).first));
    await tester.pump(const Duration(milliseconds: 700));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.byKey(contextMenuKey), findsNothing);
  });

  testWidgets('搜索框旁的键盘按钮打开屏幕键盘，点字母就写进搜索框', (tester) async {
    WindowShell.debugTouchOverride = true;
    await pumpPane(tester);

    await tester.tap(find.byTooltip('屏幕键盘'));
    await tester.pumpAndSettle();
    expect(find.byType(SoftKeyboard), findsOneWidget);

    await tester.tap(find.descendant(
        of: find.byType(SoftKeyboard), matching: find.text('S')));
    await tester.pumpAndSettle();
    expect(provider.query, 's');
  });
}
