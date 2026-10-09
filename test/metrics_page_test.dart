import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/data/metric_database.dart';
import 'package:xgame_desktop/data/metric_store.dart';
import 'package:xgame_desktop/native/gamepad.dart';
import 'package:xgame_desktop/native/hwprobe_service.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/state/apps_provider.dart';
import 'package:xgame_desktop/state/metrics_provider.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/state/weather_provider.dart';
import 'package:xgame_desktop/ui/home_screen.dart';
import 'package:xgame_desktop/ui/metrics_page.dart';
import 'package:xgame_desktop/ui/title_bar.dart';

/// The providers the shell always has; these tests only need them present and
/// quiet (the monitoring page's own cases never touch them).
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

class _QuietPad extends GamepadService {
  @override
  void start() {}
}

void main() {
  late Directory dataDir;
  var now = DateTime.utc(2026, 3, 1, 12);

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_metrics_page');
    now = DateTime.utc(2026, 3, 1, 12);
  });

  tearDown(() {
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A whole reading, so every card has something to draw.
  Map<MetricField, double?> sample(int i) => {
        MetricField.cpuPct: (i % 25) + 5,
        MetricField.cpuTemp: 40 + (i % 20).toDouble(),
        MetricField.cpuFreqMhz: 3600 + (i % 7) * 100,
        MetricField.cpuPowerW: 35 + (i % 25).toDouble(),
        MetricField.gpuPct: ((i % 25) + 5) / 2,
        MetricField.gpuTemp: 45 + (i % 15).toDouble(),
        MetricField.gpuPowerW: 90 + (i % 60).toDouble(),
        MetricField.gpuMemMb: 4000 + i.toDouble(),
        MetricField.memPct: 50 + (i % 10).toDouble(),
        MetricField.memUsedMb: 12000 + i.toDouble(),
        MetricField.diskPct: (i % 30).toDouble(),
        MetricField.diskReadKbps: (i * 100).toDouble(),
        MetricField.diskWriteKbps: (i * 50).toDouble(),
        MetricField.netDownKbps: (i * 1000).toDouble(),
        MetricField.netUpKbps: (i * 100).toDouble(),
        MetricField.fanRpm: 1000 + (i % 500).toDouble(),
      };

  /// Writes [count] readings into the history, one every [stepSeconds], the
  /// newest one a step before [now] — the recorder's own first reading lands on
  /// [now] and the two must not collide.
  void seed(int count, {int stepSeconds = 3}) {
    final db = MetricDatabase.open(dataDir);
    for (var i = 0; i < count; i++) {
      final at = now.subtract(Duration(seconds: (count - i) * stepSeconds));
      db.store().put(at, sample(i));
    }
    db.close();
  }

  /// A recorder over the temp folder, already collecting at the default rate.
  MetricsProvider recorder(MetricSource source) {
    final metrics = MetricsProvider(dataDir: dataDir, clock: () => now)
      ..attach(source);
    addTearDown(metrics.dispose);
    metrics.start();
    return metrics;
  }

  Future<void> pumpPage(
    WidgetTester tester,
    MetricsProvider metrics, {
    VoidCallback? onClose,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<MetricsProvider>.value(
        value: metrics,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(body: MetricsPage(onClose: onClose ?? () {})),
        ),
      ),
    );
    // The page never settles: the recorder's timer keeps ticking, and every
    // step below is a fixed pump.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Takes the page down and stops the recorder: a live `Timer.periodic` would
  /// otherwise still be pending when the test ends.
  Future<void> teardown(WidgetTester tester, MetricsProvider metrics) async {
    await tester.pumpWidget(const SizedBox.shrink());
    metrics.dispose();
  }

  testWidgets('有历史时画出卡片、读数与条数', (tester) async {
    seed(40);
    final metrics = recorder(() => {MetricField.cpuPct: 12});
    await pumpPage(tester, metrics);

    expect(find.text('设备监控'), findsOneWidget);
    expect(find.textContaining('共 41 条'), findsOneWidget);
    expect(find.textContaining('只留近 7 天'), findsOneWidget);
    expect(find.text('占用率'), findsOneWidget);
    expect(find.text('温度'), findsOneWidget);
    expect(find.text('内存占用率'), findsOneWidget);
    expect(find.text('网络速率'), findsOneWidget);
    expect(find.text('磁盘活动'), findsOneWidget);
    expect(find.text('风扇转速'), findsOneWidget);
    expect(find.text('清空记录'), findsOneWidget);
    expect(find.text('还没有采集到数据'), findsNothing);
    expect(find.text('无数据'), findsNothing, reason: '每条读数都有值');
    // 每个区间的开关都在，默认是 1 小时。
    for (final range in MetricRange.values) {
      expect(find.text(range.label), findsOneWidget);
    }
    // 图下的图例把这一段的均值与峰值写出来了。
    expect(find.textContaining('CPU 占用率 均'), findsOneWidget);
    expect(find.textContaining('· 峰'), findsWidgets);

    await teardown(tester, metrics);
  });

  testWidgets('区间切换换一段窗口：两小时前的尖峰只在长窗口里出现', (tester) async {
    final db = MetricDatabase.open(dataDir);
    db.store().put(now.subtract(const Duration(hours: 2)),
        {MetricField.cpuPct: 99});
    for (var i = 0; i < 5; i++) {
      db.store().put(now.subtract(Duration(minutes: i)),
          {MetricField.cpuPct: 5});
    }
    db.close();

    final metrics = recorder(() => {MetricField.cpuPct: 5});
    await pumpPage(tester, metrics);

    expect(find.textContaining('峰 99.0 %'), findsNothing, reason: '默认只看 1 小时');

    await tester.tap(find.text('24 小时'));
    await tester.pump();
    expect(find.textContaining('峰 99.0 %'), findsOneWidget);
    // 5 分钟前那条也进了这个窗口：卡片右上角的当前值就是它。
    expect(find.text('5.0 %'), findsOneWidget);

    await tester.tap(find.text('1 小时'));
    await tester.pump();
    expect(find.textContaining('峰 99.0 %'), findsNothing);

    await teardown(tester, metrics);
  });

  testWidgets('没有记录时给空态，清空记录按不动', (tester) async {
    final metrics = recorder(
        () => {for (final field in MetricField.values) field: null});
    await pumpPage(tester, metrics);

    expect(find.text('还没有采集到数据'), findsOneWidget);
    expect(find.text('占用率'), findsNothing);

    await tester.tap(find.text('清空记录'));
    await tester.pump();
    expect(find.text('确认清空'), findsNothing, reason: '没有记录可清，第一步就不该发生');

    await teardown(tester, metrics);
  });

  testWidgets('采集没能启动时，空态说的是这件事', (tester) async {
    final metrics = MetricsProvider(dataDir: dataDir, clock: () => now);
    addTearDown(metrics.dispose);
    await pumpPage(tester, metrics);

    expect(find.text('设备信息采集没有启动'), findsOneWidget);
    expect(find.text('还没有采集到数据'), findsNothing);

    await teardown(tester, metrics);
  });

  testWidgets('清空记录要按两次：第一次只出确认条，取消就收回去', (tester) async {
    seed(20);
    final metrics = recorder(() => {MetricField.cpuPct: 5});
    await pumpPage(tester, metrics);
    expect(metrics.sampleCount, 21);

    await tester.tap(find.text('清空记录'));
    await tester.pump();
    expect(find.textContaining('清空后无法恢复'), findsOneWidget);
    expect(find.text('确认清空'), findsOneWidget);
    expect(metrics.sampleCount, 21, reason: '第一次按只是问一句，不该动数据');

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.text('确认清空'), findsNothing);
    expect(metrics.sampleCount, 21);

    await tester.tap(find.text('清空记录'));
    await tester.pump();
    await tester.tap(find.text('确认清空'));
    await tester.pump();

    expect(metrics.sampleCount, 0);
    expect(find.text('还没有采集到数据'), findsOneWidget);

    await teardown(tester, metrics);
  });

  testWidgets('Esc 与关闭按钮都能退出监控页', (tester) async {
    seed(5);
    var closed = 0;
    final metrics = recorder(() => {MetricField.cpuPct: 1});
    await pumpPage(tester, metrics, onClose: () => closed++);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);

    await tester.tap(find.byKey(const Key('metricsClose')));
    await tester.pump();
    expect(closed, 2);

    await teardown(tester, metrics);
  });

  testWidgets('标题栏的监控图标是入口，未接线时不显示', (tester) async {
    var taps = 0;
    final settings = SettingsProvider(dataDir: dataDir)
      ..wallpaperEngineLocator = () => null;
    addTearDown(settings.dispose);
    Widget host(TitleBar bar) =>
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: MaterialApp(
            theme: buildTheme(appPalettes.first),
            home: Scaffold(body: bar),
          ),
        );

    await tester.pumpWidget(host(TitleBar(onToggleMetrics: () => taps++)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.monitor_heart_outlined));
    await tester.pumpAndSettle();
    expect(taps, 1);

    await tester.pumpWidget(host(const TitleBar()));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.monitor_heart_outlined), findsNothing);
  });

  testWidgets('外壳：监控页从标题栏打开，开设置页时它让位', (tester) async {
    final settings = SettingsProvider(dataDir: dataDir)
      ..wallpaperEngineLocator = () => null;
    addTearDown(settings.dispose);
    final apps = _QuietApps(dataDir: dataDir)
      ..apps = [
        AppEntry(name: 'Steam', path: r'C:\Start Menu\Steam.lnk'),
      ]
      ..status = AppsStatus.ready;
    addTearDown(apps.dispose);
    // The shell starts the recorder itself (and hands it the probe's readings),
    // so this one is only wired, not started.
    final metrics = MetricsProvider(dataDir: dataDir, clock: () => now);
    addTearDown(metrics.dispose);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AppsProvider>.value(value: apps),
          ChangeNotifierProvider<MetricsProvider>.value(value: metrics),
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

    expect(find.byType(MetricsPage), findsNothing);

    await tester.tap(find.byIcon(Icons.monitor_heart_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MetricsPage), findsOneWidget);

    // 开设置页：监控页让出窗口，两者不会同时铺在上面。
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MetricsPage), findsNothing);

    // 再点监控图标，它自己回来。
    await tester.tap(find.byIcon(Icons.monitor_heart_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MetricsPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    metrics.dispose();
  });
}
