import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/ui/context_menu.dart';

void main() {
  final fired = <String>[];

  setUp(fired.clear);

  Future<void> pumpHost(
    WidgetTester tester,
    void Function(BuildContext context, Offset position) onOpen,
  ) {
    return tester.pumpWidget(
      // 菜单面板是毛玻璃，会问设置“背后有没有壁纸”；这里没有壁纸，
      // 玻璃照规矩降级成半透明填充。
      ChangeNotifierProvider<SettingsProvider>.value(
        value: SettingsProvider(),
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(
            body: Builder(
              builder: (context) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onSecondaryTapUp: (details) =>
                    onOpen(context, details.globalPosition),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the menu at [at] with a small two-group menu.
  Future<void> openAt(WidgetTester tester, Offset at,
      {bool withDisabled = false}) async {
    await pumpHost(tester, (context, position) {
      showContextMenu(
        context,
        position: position,
        entries: [
          ContextMenuAction(
            label: '打开',
            icon: Icons.play_arrow_rounded,
            onTap: () => fired.add('open'),
          ),
          const ContextMenuDivider(),
          ContextMenuAction(
            label: '打开文件位置',
            icon: Icons.folder_open_rounded,
            onTap: () => fired.add('folder'),
          ),
          if (withDisabled)
            ContextMenuAction(
              label: '卸载',
              icon: Icons.delete_outline_rounded,
              enabled: false,
              onTap: () => fired.add('uninstall'),
            ),
        ],
      );
    });
    await tester.tapAt(at, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  testWidgets('菜单的角贴住点击处，不再跑到窗口另一边', (tester) async {
    await openAt(tester, const Offset(300, 200));

    expect(find.byKey(contextMenuKey), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(contextMenuKey)),
        const Offset(300, 200));
    // The menu is not a stock popup: it carries the app's raised surface.
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('打开文件位置'), findsOneWidget);
  });

  testWidgets('靠近窗口右下角时，菜单向左上翻转，仍在窗口内', (tester) async {
    const anchor = Offset(700, 560);
    await openAt(tester, anchor);

    final rect = tester.getRect(find.byKey(contextMenuKey));
    // Flipped: the near corner is the bottom-right one, so the menu hangs
    // above and to the left of the pointer.
    expect(rect.bottomRight, anchor);
    expect(rect.top, lessThan(anchor.dy));
    expect(rect.left, greaterThanOrEqualTo(8));
    expect(rect.top, greaterThanOrEqualTo(8));
    expect(rect.right, lessThanOrEqualTo(800 - 8));
    expect(rect.bottom, lessThanOrEqualTo(600 - 8));
  });

  testWidgets('点菜单项触发回调并关闭菜单', (tester) async {
    await openAt(tester, const Offset(200, 150));

    await tester.tap(find.text('打开文件位置'));
    await tester.pumpAndSettle();

    expect(fired, ['folder']);
    expect(find.byKey(contextMenuKey), findsNothing);
  });

  testWidgets('点菜单外面只关闭菜单，不触发任何项', (tester) async {
    await openAt(tester, const Offset(200, 150));

    await tester.tapAt(const Offset(60, 60));
    await tester.pumpAndSettle();

    expect(fired, isEmpty);
    expect(find.byKey(contextMenuKey), findsNothing);
  });

  testWidgets('Esc 关闭菜单', (tester) async {
    await openAt(tester, const Offset(200, 150));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(fired, isEmpty);
    expect(find.byKey(contextMenuKey), findsNothing);
  });

  testWidgets('方向键走条目、回车执行，禁用项被跳过', (tester) async {
    await openAt(tester, const Offset(200, 150), withDisabled: true);

    // First Enter runs the first row.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fired, ['open']);

    await openAt(tester, const Offset(200, 150), withDisabled: true);
    // Down twice walks past the divider and the disabled row.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fired, ['open', 'folder']);
  });

  testWidgets('禁用项点了不触发，菜单保持打开', (tester) async {
    await openAt(tester, const Offset(200, 150), withDisabled: true);

    await tester.tap(find.text('卸载'));
    await tester.pumpAndSettle();

    expect(fired, isEmpty);
    expect(find.byKey(contextMenuKey), findsOneWidget);
  });
}
