import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/native/gamepad.dart';
import 'package:xgame_desktop/native/hwprobe_service.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/state/apps_provider.dart';
import 'package:xgame_desktop/state/metrics_provider.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/state/weather_provider.dart';
import 'package:xgame_desktop/ui/home_screen.dart';
import 'package:xgame_desktop/ui/stats_page.dart';
import 'package:xgame_desktop/ui/title_bar.dart';

/// The real providers reach for the machine: a native poller, a Start-menu
/// scan, a weather request. These tests only need them present and quiet.
class _QuietApps extends AppsProvider {
  _QuietApps({super.dataDir})
      : super(launcher: (_) => true, scanner: () async => const []);

  @override
  Future<void> load() async {}
}

class _QuietProbe extends HwprobeService {
  @override
  Future<void> start() async {}

  @override
  Future<void> shutdown() async {}
}

class _QuietWeather extends WeatherProvider {
  @override
  void start() {}
}

/// No pad, no timer.
class _QuietPad extends GamepadService {
  @override
  void start() {}
}

/// The recorder reaches for the machine's profile database; the shell only
/// needs it present here (the monitoring page has its own tests).
class _QuietMetrics extends MetricsProvider {
  _QuietMetrics({super.dataDir});

  @override
  void start({Duration? interval}) {}
}

void main() {
  late Directory dataDir;
  late List<AppEntry> catalog;

  AppEntry entry(String name) =>
      AppEntry(name: name, path: 'C:\\Start Menu\\$name.lnk', hasDesktop: true);

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_stats');
    catalog = [entry('Steam'), entry('ZCode'), entry('WeGame')];
  });

  tearDown(() {
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A provider over the temp data dir. Its `load` is the real one, so the
  /// launch history is read back from `app_usage`; only the machine scan is
  /// stood in for.
  AppsProvider newProvider() {
    final apps = AppsProvider(
      dataDir: dataDir,
      launcher: (_) => true,
      scanner: () async => catalog,
    );
    addTearDown(apps.dispose);
    return apps;
  }

  Future<void> pumpPage(
    WidgetTester tester,
    AppsProvider apps, {
    VoidCallback? onClose,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppsProvider>.value(
        value: apps,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(body: StatsPage(onClose: onClose ?? () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // `load()` builds the search index behind a 900 ms hold timer; let it
    // expire so no timer outlives the test.
    await tester.pump(const Duration(milliseconds: 1000));
  }

  testWidgets('没有记录时给空态，清空统计按不动', (tester) async {
    final apps = newProvider();
    await apps.load();
    await pumpPage(tester, apps);

    expect(find.text('还没有启动记录'), findsOneWidget);
    expect(find.text('总启动次数'), findsNothing);
    expect(find.text('清空统计'), findsOneWidget);

    await tester.tap(find.text('清空统计'));
    await tester.pumpAndSettle();
    expect(find.text('确认清空'), findsNothing, reason: '没有记录可清，第一步就不该发生');
  });

  testWidgets('按次数排名次，给出次数与占比，只列启动过的', (tester) async {
    final apps = newProvider();
    await apps.load();
    apps
      ..launch(catalog[0])
      ..launch(catalog[0])
      ..launch(catalog[0])
      ..launch(catalog[1]);
    await pumpPage(tester, apps);

    expect(find.text('共 4 次'), findsOneWidget);
    expect(find.text('总启动次数'), findsOneWidget);
    expect(find.text('记录的应用'), findsOneWidget);
    expect(find.text('最常启动'), findsOneWidget);
    // 最常启动那张卡和排行榜第一行都写着同一个名字。
    expect(find.text('Steam'), findsNWidgets(2));
    expect(find.text('ZCode'), findsOneWidget);
    expect(find.text('WeGame'), findsNothing, reason: '没启动过就不在统计里');

    expect(find.text('75%'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    // 次数多的排在上面。
    expect(tester.getTopLeft(find.text('75%')).dy,
        lessThan(tester.getTopLeft(find.text('25%')).dy));
  });

  testWidgets('清空统计要按两次：第一次只出确认条，取消就收回去', (tester) async {
    final apps = newProvider();
    await apps.load();
    apps.launch(catalog[0]);
    await pumpPage(tester, apps);
    expect(apps.totalLaunches, 1);

    await tester.tap(find.text('清空统计'));
    await tester.pumpAndSettle();
    expect(find.textContaining('清空后无法恢复'), findsOneWidget);
    expect(find.text('确认清空'), findsOneWidget);
    expect(apps.totalLaunches, 1, reason: '第一次按只是问一句，不该动数据');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('确认清空'), findsNothing);
    expect(apps.totalLaunches, 1);

    await tester.tap(find.text('清空统计'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认清空'));
    await tester.pumpAndSettle();

    expect(apps.totalLaunches, 0);
    expect(find.text('还没有启动记录'), findsOneWidget);
    expect(find.text('共 1 次'), findsNothing);
  });

  testWidgets('Esc 与关闭按钮都能退出统计页', (tester) async {
    var closed = 0;
    final apps = newProvider();
    await apps.load();
    await pumpPage(tester, apps, onClose: () => closed++);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(closed, 1);

    await tester.tap(find.byKey(const Key('statsClose')));
    await tester.pumpAndSettle();
    expect(closed, 2);
  });

  testWidgets('标题栏的统计图标是入口，未接线时不显示', (tester) async {
    var taps = 0;
    final settings = SettingsProvider(dataDir: dataDir)
      ..wallpaperEngineLocator = () => null;
    addTearDown(settings.dispose);
    Widget host(TitleBar bar) => ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: MaterialApp(
            theme: buildTheme(appPalettes.first),
            home: Scaffold(body: bar),
          ),
        );

    await tester.pumpWidget(host(TitleBar(onToggleStats: () => taps++)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.insights_outlined));
    await tester.pumpAndSettle();
    expect(taps, 1);

    await tester.pumpWidget(host(const TitleBar()));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.insights_outlined), findsNothing);
  });

  testWidgets('外壳：统计页从标题栏打开，开设置页时它让位', (tester) async {
    // The shell keeps a clock ticking, so it never "settles": every step below
    // is a fixed pump, the way the other shell tests drive it.
    final settings = SettingsProvider(dataDir: dataDir)
      ..wallpaperEngineLocator = () => null;
    addTearDown(settings.dispose);
    final apps = _QuietApps(dataDir: dataDir)
      ..apps = [catalog[0], catalog[1]]
      ..status = AppsStatus.ready;
    addTearDown(apps.dispose);
    apps.launch(catalog[0]);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AppsProvider>.value(value: apps),
          ChangeNotifierProvider<MetricsProvider>.value(
              value: _QuietMetrics(dataDir: dataDir)),
          ChangeNotifierProvider<HwprobeService>.value(value: _QuietProbe()),
          ChangeNotifierProvider<WeatherProvider>.value(value: _QuietWeather()),
          ChangeNotifierProvider<GamepadService>.value(value: _QuietPad()),
        ],
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: const HomeScreen(bootScreen: false),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(StatsPage), findsNothing);

    await tester.tap(find.byIcon(Icons.insights_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(StatsPage), findsOneWidget);
    expect(find.text('共 1 次'), findsOneWidget);

    // 开设置页：统计页让出窗口，两者不会同时铺在上面。
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(StatsPage), findsNothing);

    // 再点统计图标，它自己回来。
    await tester.tap(find.byIcon(Icons.insights_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(StatsPage), findsOneWidget);
  });
}
