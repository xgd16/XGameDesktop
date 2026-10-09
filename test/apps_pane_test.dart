import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/data/app_database.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/state/apps_provider.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/ui/app_card.dart';
import 'package:xgame_desktop/ui/apps_pane.dart';
import 'package:xgame_desktop/ui/context_menu.dart';
import 'package:xgame_desktop/ui/game_card.dart';

void main() {
  late AppsProvider provider;
  late Directory dataDir;
  final launched = <String>[];

  /// A provider over the temp data dir, released with the test. It holds the
  /// profile database open, and Windows will not delete the directory until it
  /// lets go.
  AppsProvider newProvider({bool Function(String path)? launcher}) {
    final apps = AppsProvider(dataDir: dataDir, launcher: launcher);
    addTearDown(apps.dispose);
    return apps;
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_test');
    launched.clear();
    // Never loaded from disk and never actually launching anything.
    provider = newProvider(launcher: (path) {
      launched.add(path);
      return true;
    })
      ..apps = [
        AppEntry(
          name: 'Steam',
          path: r'C:\Start Menu\Steam.lnk',
          hasDesktop: true,
        ),
        AppEntry(name: 'Notepad++', path: r'C:\Start Menu\Notepad++.lnk'),
        AppEntry(
          name: 'Command Prompt',
          path: r'C:\Start Menu\System Tools\Command Prompt.lnk',
          isSystem: true,
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

  Future<void> pumpPane(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppsProvider>.value(
        value: provider,
        // 毛玻璃会问设置“背后有没有壁纸”；这些用例测的是网格本身，
        // 没有壁纸，玻璃照规矩降级成半透明填充。
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

  List<String> gridNames(WidgetTester tester) => tester
      .widgetList<AppCard>(find.byType(AppCard))
      .map((card) => card.app.name)
      .toList();

  testWidgets('「推荐」初始为空：没启动过的应用不出现', (tester) async {
    await pumpPane(tester);

    expect(find.text('推荐 0'), findsOneWidget);
    expect(find.text('桌面 1'), findsOneWidget);
    expect(find.byType(AppCard), findsNothing);
    expect(find.text('启动过的应用会按使用频率出现在这里'), findsOneWidget);
  });

  testWidgets('启动过的应用进入「推荐」，点击越多排越靠前', (tester) async {
    await pumpPane(tester);

    final steam = provider.apps[0];
    final notepad = provider.apps[1];
    for (var i = 0; i < 3; i++) {
      expect(provider.launch(steam), isTrue);
    }
    provider.launch(notepad);
    await tester.pumpAndSettle();

    expect(launched, hasLength(4));
    expect(gridNames(tester), ['Steam', 'Notepad++']);
    expect(provider.launchCount(steam), 3);

    // Never launched, so still absent even though it sorts first by name.
    expect(gridNames(tester), isNot(contains('Command Prompt')));

    // The counting is written to the profile database for the next run.
    final db = AppDatabase.open(dataDir);
    try {
      final row = db.activityStore().launch(r'c:\start menu\steam.lnk')!;
      expect(row.launches, 3);
      expect(row.name, 'Steam');
      expect(row.lastLaunch, isNotNull);
      expect(db.activityStore().totalLaunches, 4);
    } finally {
      db.close();
    }
  });

  testWidgets('「桌面」只列桌面上的应用', (tester) async {
    await pumpPane(tester);
    await tester.tap(find.text('桌面 1'));
    await tester.pumpAndSettle();

    expect(gridNames(tester), ['Steam']);
  });

  testWidgets('同排卡片按固定槽位对齐，名字长短不影响图标与文字位置', (tester) async {
    provider = newProvider(launcher: (_) => true)
      ..apps = [
        for (final (i, name) in [
          'Steam',
          'Epic Games Launcher',
          'ZCode',
          'Developer Command Prompt for VS 2022',
        ].indexed)
          AppEntry(name: name, path: r'C:\apps\' 'app$i.lnk', hasDesktop: true),
      ]
      ..status = AppsStatus.ready;
    await pumpPane(tester);
    await tester.tap(find.text('桌面 4'));
    await tester.pumpAndSettle();

    final cards = find.byType(AppCard);
    expect(cards, findsNWidgets(4));

    final cardTops = <double>[];
    final labelTops = <double>[];
    final iconCentres = <double>[];
    for (var i = 0; i < 4; i++) {
      final card = cards.at(i);
      final cardRect = tester.getRect(card);
      cardTops.add(cardRect.top);

      final label = cardRect.top + 73; // 12 pad + 1 border + 52 icon + 8 gap
      labelTops.add(tester.getRect(
        find.descendant(of: card, matching: find.byType(Text)).last,
      ).top);
      expect(labelTops.last, moreOrLessEquals(label, epsilon: 0.01),
          reason: 'label slot must start right below the fixed icon slot');

      // The letter placeholder is the first Text inside the card's icon slot.
      final icon = find.descendant(of: card, matching: find.byType(Text)).first;
      iconCentres.add(tester.getRect(icon).center.dy);
    }

    final rowTop = cardTops.first;
    for (var i = 0; i < 4; i++) {
      expect(cardTops[i], moreOrLessEquals(rowTop, epsilon: 0.01),
          reason: 'all four cards share one grid row');
      expect(iconCentres[i], moreOrLessEquals(iconCentres.first, epsilon: 0.01),
          reason: 'icon centres must line up regardless of name length');
      expect(labelTops[i], moreOrLessEquals(labelTops.first, epsilon: 0.01),
          reason: 'label tops must line up regardless of name length');
    }
  });

  testWidgets('卡片入场动画只播首屏一次，滚动出来的卡片直接就位', (tester) async {
    provider = newProvider(launcher: (_) => true)
      ..apps = [
        for (var i = 0; i < 200; i++)
          AppEntry(name: 'App $i', path: r'C:\apps\app$i.lnk', hasDesktop: true),
      ]
      ..status = AppsStatus.ready;
    await pumpPane(tester);
    await tester.tap(find.text('桌面 200'));
    await tester.pump(); // 网格的第一帧

    List<double> cardOpacities() => tester
        .widgetList<Opacity>(find.descendant(
            of: find.byType(GridView), matching: find.byType(Opacity)))
        .map((o) => o.opacity)
        .toList();

    expect(cardOpacities(), isNotEmpty);
    expect(cardOpacities().any((v) => v < 1), isTrue,
        reason: '首屏卡片应当还在入场淡入');

    await tester.pump(const Duration(seconds: 2)); // 延迟到点，动画开跑
    await tester.pumpAndSettle(); // 首波播完
    expect(cardOpacities().every((v) => v == 1), isTrue);

    await tester.drag(find.byType(GridView), const Offset(0, -1600));
    await tester.pump(); // 滚动新出现的卡片已构建
    expect(cardOpacities().every((v) => v == 1), isTrue,
        reason: '滚动新出现的卡片不应重放入场动画');
    await tester.pumpAndSettle();
  });

  testWidgets('列表里不显示的隐藏应用，也可以被搜索到', (tester) async {
    await pumpPane(tester);
    // Command Prompt 与 Notepad++ 都不在「桌面」分类里。
    expect(gridNames(tester), isEmpty);

    provider.setQuery('command');
    await tester.pumpAndSettle();
    expect(gridNames(tester), ['Command Prompt']);

    // 在「桌面」分类下搜索同样能找到非桌面应用（搜索覆盖整个目录）。
    await tester.tap(find.text('桌面 1'));
    await tester.pumpAndSettle();
    provider.setQuery('notepad');
    await tester.pumpAndSettle();
    expect(gridNames(tester), ['Notepad++']);
  });

  testWidgets('建立搜索索引时，搜索框里显示进度', (tester) async {
    provider = newProvider(launcher: (_) => true)
      ..apps = [
        for (var i = 0; i < 3000; i++)
          AppEntry(name: 'Application Number $i', path: r'C:\apps\app$i.lnk'),
      ]
      ..status = AppsStatus.ready;
    await pumpPane(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final build = provider.buildSearchIndex();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('正在建立搜索索引'), findsOneWidget);

    await tester.pumpAndSettle();
    await build;
    await tester.pump();
    expect(find.textContaining('搜索索引已就绪'), findsOneWidget);

    // 停留片刻后整条进度消失，搜索框回到普通提示。
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('搜索应用'), findsOneWidget);
  });

  testWidgets('搜索无结果时的空态文案', (tester) async {
    await pumpPane(tester);
    provider.setQuery('zzz');
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的应用,试试关键词或首字母'), findsOneWidget);

    // 搜索覆盖整个目录，切分类不改变结果文案。
    await tester.tap(find.text('桌面 1'));
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的应用,试试关键词或首字母'), findsOneWidget);

    provider.setQuery('steam');
    await tester.pumpAndSettle();
    expect(gridNames(tester), ['Steam']);
  });

  testWidgets('磁贴右键菜单：打开、打开文件位置、复制路径', (tester) async {
    final clipboard = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpPane(tester);
    await tester.tap(find.text('桌面 1'));
    await tester.pumpAndSettle();

    // Right-click the tile: the menu opens at the pointer.
    final tile = find.byType(AppCard);
    final target = tester.getCenter(tile);
    await tester.tapAt(target, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.byKey(contextMenuKey)), target);
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('打开文件位置'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);

    await tester.tap(find.text('复制路径'));
    await tester.pumpAndSettle();
    expect(clipboard.single.arguments['text'], r'C:\Start Menu\Steam.lnk');
    expect(find.text('已复制路径'), findsOneWidget);
    expect(find.byKey(contextMenuKey), findsNothing);

    // Let the toast time out so no timer outlives the test.
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();

    // And the plain primary action still launches through the injected runner.
    await tester.tapAt(target, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(launched, [r'C:\Start Menu\Steam.lnk']);
  });

  testWidgets('固定到首页：钉选置顶、带角标、菜单可取消', (tester) async {
    await pumpPane(tester);

    // 桌面页签上的 Steam 磁贴，右键固定。
    await tester.tap(find.text('桌面 1'));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(AppCard)),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('固定到首页'));
    await tester.pumpAndSettle();

    expect(provider.isPinned(provider.apps[0]), isTrue);
    // 钉选写进 app_pin 表：键就是小写的路径。
    final db = AppDatabase.open(dataDir);
    try {
      expect(db.activityStore().pinned(), [r'c:\start menu\steam.lnk']);
    } finally {
      db.close();
    }

    // 从未启动过的应用，钉选后也进「推荐」，并带角标。
    expect(find.text('推荐 1'), findsOneWidget);
    await tester.tap(find.text('推荐 1'));
    await tester.pumpAndSettle();
    expect(gridNames(tester), ['Steam']);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);

    // 菜单里取消固定，「推荐」回到空态。
    await tester.tapAt(tester.getCenter(find.byType(AppCard)),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消固定'));
    await tester.pumpAndSettle();
    expect(find.text('推荐 0'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsNothing);
  });

  testWidgets('钉选顺序：上移把它往前挪一格，钉选块整体压过启动次数', (tester) async {
    final steam = provider.apps[0];
    final notepad = provider.apps[1];
    final prompt = provider.apps[2];
    // Command Prompt 用得最多，但钉选块压过启动次数。
    for (var i = 0; i < 5; i++) {
      provider.launch(prompt);
    }
    provider.pin(steam);
    provider.pin(notepad);
    await pumpPane(tester);

    expect(gridNames(tester), ['Steam', 'Notepad++', 'Command Prompt']);

    await tester.tapAt(tester.getCenter(find.text('Notepad++')),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('上移'));
    await tester.pumpAndSettle();
    expect(gridNames(tester), ['Notepad++', 'Steam', 'Command Prompt']);
  });

  testWidgets('分类 chips：按类别过滤，空结果有提示', (tester) async {
    provider = newProvider(launcher: (_) => true)
      ..apps = [
        AppEntry(name: 'Steam', path: r'C:\S\Steam.lnk', hasDesktop: true),
        AppEntry(
          name: '英雄联盟',
          path: r'C:\S\lol.lnk',
          hasDesktop: true,
          category: AppCategory.game,
        ),
        AppEntry(name: 'Notepad++', path: r'C:\S\npp.lnk'),
      ]
      ..status = AppsStatus.ready;
    await pumpPane(tester);
    await tester.tap(find.text('桌面 2'));
    await tester.pumpAndSettle();

    // 计数描述的是当前页签里的列表（桌面页签只有 Steam 和 英雄联盟），
    // 为 0 的分类不出现。
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('游戏 1'), findsOneWidget);
    expect(find.text('应用 1'), findsOneWidget);
    expect(find.text('系统 1'), findsNothing);

    await tester.tap(find.text('游戏 1'));
    await tester.pumpAndSettle();
    expect(gridNames(tester), ['英雄联盟']);

    // 过滤带到「推荐」，那里没有启动过的游戏——空态给出分类提示。
    await tester.tap(find.text('推荐 0'));
    await tester.pumpAndSettle();
    expect(find.text('这个分类下暂时没有应用,换个分类或回到全部'), findsOneWidget);
  });

  testWidgets('没有 Steam 游戏时不出现「游戏」页签', (tester) async {
    await pumpPane(tester);
    expect(find.textContaining('游戏 '), findsNothing);
  });

  testWidgets('游戏页签：封面墙卡片，A 键（点击）走 steam 协议启动', (tester) async {
    provider = newProvider(launcher: (p) {
      launched.add(p);
      return true;
    })
      ..apps = [
        AppEntry(name: 'Steam', path: r'C:\S\Steam.lnk', hasDesktop: true),
        AppEntry(
          name: 'Project Zomboid',
          path: 'steam://rungameid/4000',
          isGame: true,
          category: AppCategory.game,
        ),
        AppEntry(
          name: 'Stardew Valley',
          path: 'steam://rungameid/413150',
          isGame: true,
          category: AppCategory.game,
        ),
      ]
      ..status = AppsStatus.ready;
    await pumpPane(tester);

    // 「推荐」还空着，页签上的「游戏 2」是唯一的（分类条按视图计数，空
    // 视图下整条隐藏）。
    expect(find.text('游戏 2'), findsOneWidget);
    await tester.tap(find.text('游戏 2'));
    await tester.pumpAndSettle();

    // 封面墙用 GameCard 渲染；没有本地封面时是字母块（离线不拉网）。
    expect(find.byType(GameCard), findsNWidgets(2));
    expect(find.text('P'), findsOneWidget);
    // 游戏架本身就是分类，不显示分类过滤条。
    expect(find.text('全部'), findsNothing);

    await tester.tap(find.text('Project Zomboid'));
    await tester.pumpAndSettle();
    expect(launched, ['steam://rungameid/4000']);
  });
}
