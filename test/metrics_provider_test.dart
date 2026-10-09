import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/data/metric_database.dart';
import 'package:xgame_desktop/data/metric_store.dart';
import 'package:xgame_desktop/native/hwprobe_service.dart';
import 'package:xgame_desktop/state/app_activity.dart';
import 'package:xgame_desktop/state/metrics_provider.dart';

/// The recorder: a row every interval, a rate the setting can move, nothing
/// written while the window is hidden, and a week of history with the rest
/// swept away.
void main() {
  late Directory dir;
  var now = DateTime.utc(2026, 3, 1, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xg_metrics');
    now = DateTime.utc(2026, 3, 1, 12);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // An open connection can hold the file; the temp folder is a scratch pad.
    }
  });

  /// A recorder over the temp folder, stamped by the fake clock. Nothing is
  /// started here: each case decides that for itself.
  MetricsProvider recorder(MetricSource source) {
    final provider = MetricsProvider(dataDir: dir, clock: () => now)
      ..attach(source);
    addTearDown(provider.dispose);
    return provider;
  }

  /// Lets [times] intervals pass for both clocks at once: the test binding's,
  /// which fires the timer, and the recorder's, which stamps the row. One
  /// interval per step — two ticks that land on the same moment are one row by
  /// design, so a single leap would hide the second one.
  Future<void> pass(
    WidgetTester tester,
    int seconds,
    int times,
  ) async {
    for (var i = 0; i < times; i++) {
      now = now.add(Duration(seconds: seconds));
      await tester.pump(Duration(seconds: seconds));
    }
  }

  testWidgets('起步先采一条，之后按间隔走，改了间隔立刻按新的走', (tester) async {
    var value = 0.0;
    final metrics = recorder(() => {MetricField.cpuPct: value += 5});

    metrics.start();
    expect(metrics.active, isTrue);
    expect(metrics.sampleCount, 1, reason: '不等一个间隔，页面一打开就有曲线');

    await pass(tester, 3, 2);
    expect(metrics.sampleCount, 3);

    metrics.setInterval(const Duration(seconds: 1));
    await pass(tester, 1, 4);
    expect(metrics.sampleCount, 7, reason: '新的间隔从计时器重开的那一刻算');

    metrics.dispose();
  });

  testWidgets('间隔被夹在 1 秒到 5 分钟之间', (tester) async {
    final metrics = recorder(() => {MetricField.cpuPct: 1});

    metrics.setInterval(const Duration(milliseconds: 200));
    expect(metrics.interval, MetricsProvider.minInterval);
    metrics.setInterval(const Duration(hours: 2));
    expect(metrics.interval, MetricsProvider.maxInterval);
    metrics.setInterval(const Duration(seconds: 10));
    expect(metrics.interval, const Duration(seconds: 10));

    metrics.dispose();
  });

  testWidgets('窗口不可见时不写，回到前台立刻补一条', (tester) async {
    addTearDown(() => AppActivity.visible.value = true);
    final metrics = recorder(() => {MetricField.cpuPct: 1});

    metrics.start();
    expect(metrics.sampleCount, 1);

    AppActivity.visible.value = false;
    await pass(tester, 3, 3);
    expect(metrics.sampleCount, 1,
        reason: '探头自己也停了一秒轮询，这时记下来只是把旧读数再写一遍');

    AppActivity.visible.value = true;
    expect(metrics.sampleCount, 2, reason: '回到前台马上记一条，缺口就停在这里');
    await pass(tester, 3, 1);
    expect(metrics.sampleCount, 3);

    metrics.dispose();
  });

  testWidgets('一个读数都没有的时候不留空行', (tester) async {
    final metrics = recorder(
        () => {for (final field in MetricField.values) field: null});

    metrics.start();
    await pass(tester, 3, 2);

    expect(metrics.active, isTrue);
    expect(metrics.sampleCount, 0);
    expect(MetricDatabase.fileIn(dir).existsSync(), isTrue,
        reason: '库文件建好了，只是没有行可写');

    metrics.dispose();
  });

  testWidgets('扫地把 7 天前的记录删掉，之后的留着', (tester) async {
    var value = 0.0;
    final metrics = recorder(() => {MetricField.cpuPct: value += 1});

    metrics.start();
    final old = metrics.lastSample;
    expect(old, isNotNull);

    // 时间推后 8 天，再采满一轮（pruneEvery 条）——扫地在第 200 条时跑。
    now = now.add(const Duration(days: 8));
    for (var i = 0; i < MetricsProvider.pruneEvery; i++) {
      now = now.add(const Duration(seconds: 3));
      metrics.recordNow();
    }

    expect(metrics.sampleCount, MetricsProvider.pruneEvery,
        reason: '8 天前那一条出窗了，被删掉；新的 200 条都在');
    expect(metrics.firstSample!.isBefore(old!), isFalse);
    expect(metrics.firstSample!.isAfter(now.subtract(MetricsProvider.retention)),
        isTrue);

    metrics.dispose();
  });

  testWidgets('清空记录把表清掉，重开还是空的', (tester) async {
    final metrics = recorder(() => {MetricField.cpuPct: 3});
    metrics.start();
    await pass(tester, 3, 1);
    expect(metrics.sampleCount, 2);

    metrics.clear();
    expect(metrics.sampleCount, 0);
    expect(metrics.firstSample, isNull);
    expect(metrics.lastSample, isNull);
    metrics.dispose();

    final reopened = recorder(() => {MetricField.cpuPct: 4});
    reopened.start();
    expect(reopened.sampleCount, 1, reason: '清掉的就是清掉了，只剩刚采的这一条');
    reopened.dispose();
  });

  testWidgets('关掉再开，历史还在，曲线读得回来', (tester) async {
    final first = recorder(() => {MetricField.cpuPct: 11});
    first.start();
    await pass(tester, 3, 2);
    expect(first.sampleCount, 3);
    first.dispose();

    // 另一秒再开：同一毫秒的写入是覆盖，隔开才看得出新的那一条。
    now = now.add(const Duration(seconds: 3));
    final second = recorder(() => {MetricField.cpuPct: 22});
    second.start();
    expect(second.sampleCount, 4, reason: '上一次的历史还在，加上刚采的一条');

    final points = second.series(
      fields: [MetricField.cpuPct],
      from: now.subtract(const Duration(hours: 1)),
      to: now,
      buckets: 30,
    );
    // 四条读数（11、11、11、22）落在同一个两分钟的桶里：历史确实读回来了。
    expect(MetricPoint.mean(points, MetricField.cpuPct), closeTo(13.75, 0.001));
    second.dispose();
  });

  test('读数取自探头：风扇取最快的那一个，没有读数时全是 null', () {
    final probe = HwprobeService();
    addTearDown(probe.dispose);

    final empty = MetricsProvider.probeSource(probe)();
    expect(empty.keys.toSet(), MetricField.values.toSet());
    expect(empty.values.every((value) => value == null), isTrue);

    SensorRef fan(String code) =>
        SensorRef(4, 0, 0, code: code, name: 'Fan', unit: 'rpm');
    probe.fans = [
      FanRef(device: 'GPU', sensorName: 'Fan', ref: fan('fan')),
      FanRef(device: 'Board', sensorName: 'Fan #1', ref: fan('fan1')),
    ];
    probe.sampleFans(const [900, 1250]);

    expect(MetricsProvider.probeSource(probe)()[MetricField.fanRpm], 1250);
  });
}
