import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/data/app_database.dart';
import 'package:xgame_desktop/data/metric_database.dart';
import 'package:xgame_desktop/data/metric_store.dart';

/// The device history as it is stored: its own `metrics.db`, the
/// `metric_sample` table, the bucketed read the charts are drawn from, and the
/// seven-day retention.
void main() {
  final t0 = DateTime.utc(2026, 3, 1, 12);

  List<String> tablesOf(MetricDatabase database) => database.db
      .select("SELECT name FROM sqlite_master WHERE type = 'table' "
          'ORDER BY name')
      .map((row) => row['name'] as String)
      .toList();

  group('metric_sample：表与字段', () {
    late Directory dir;
    late MetricDatabase database;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('xg_metrics_db');
      database = MetricDatabase.open(dir);
    });
    tearDown(() {
      database.close();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('列与 MetricField 一一对应，只有时间是整数', () {
      final columns = database.db
          .select('PRAGMA table_info(${MetricStore.table})')
          .map((row) => (row['name'] as String, row['type'] as String))
          .toList();

      expect(columns.map((column) => column.$1).toList(),
          ['ts', ...MetricStore.columns]);
      expect(MetricStore.columns,
          [for (final field in MetricField.values) field.column]);
      // 时间是主键，其余每列都是 REAL：读数是小数，缺的读数是 NULL。
      expect(columns.first.$2, 'INTEGER');
      for (final column in columns.skip(1)) {
        expect(column.$2, 'REAL', reason: '${column.$1} 该是 REAL');
      }
      expect(
        database.db
            .select('PRAGMA table_info(${MetricStore.table})')
            .where((row) => row['pk'] == 1)
            .map((row) => row['name'])
            .toList(),
        ['ts'],
      );
    });

    test('历史在自己的文件里，档案库里没有这张表', () {
      final profile = AppDatabase.open(dir);
      final metricTables = tablesOf(database);
      final profileTables = profile.db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'] as String)
          .toList();

      expect(MetricDatabase.fileIn(dir).uri.pathSegments.last, 'metrics.db');
      expect(MetricDatabase.existsIn(dir), isTrue);
      expect(AppDatabase.existsIn(dir), isTrue);
      expect(metricTables, [MetricStore.table]);
      expect(profileTables, isNot(contains(MetricStore.table)));
      profile.close();
    });

    test('user_version 落在 1，重开不会重建表', () {
      expect(database.db.select('PRAGMA user_version').first.columnAt(0), 1);
      database.store().put(t0, {MetricField.cpuPct: 7});
      database.close();

      final again = MetricDatabase.open(dir);
      expect(again.store().summary.count, 1, reason: '重开不该把历史的表丢掉');
      expect(again.db.select('PRAGMA user_version').first.columnAt(0), 1);
      again.close();
      // tearDown 会再关一次，所以这里把连接换成一个新的内存库。
      database = MetricDatabase.memory();
    });

    test('内存库也能建表', () {
      final memory = MetricDatabase.memory();
      expect(memory.store().summary.count, 0);
      memory.close();
    });
  });

  group('写入、分桶与清理', () {
    late MetricDatabase database;
    late MetricStore store;

    setUp(() {
      database = MetricDatabase.memory();
      store = database.store();
    });
    tearDown(() => database.close());

    test('一行一次采集，摘要给出条数与首尾时刻', () {
      store.put(t0, {MetricField.cpuPct: 12.5, MetricField.cpuTemp: 45});
      store.put(t0.add(const Duration(seconds: 3)), {MetricField.cpuPct: 30});

      final summary = store.summary;
      expect(summary.count, 2);
      expect(summary.first, t0);
      expect(summary.last, t0.add(const Duration(seconds: 3)));
    });

    test('同一毫秒再写一次是覆盖，不是第二行', () {
      store.put(t0, {MetricField.cpuPct: 10});
      store.put(t0, {MetricField.cpuPct: 90});

      expect(store.summary.count, 1);
      final points = store.series(
        fields: [MetricField.cpuPct],
        from: t0,
        to: t0.add(const Duration(seconds: 1)),
        buckets: 1,
      );
      expect(points.single[MetricField.cpuPct], 90);
    });

    test('分桶取平均，桶的起点就是它的时刻，缺口留成 null', () {
      // 60 秒里每 3 秒一条：cpu 从 0 数到 19，温度只有前 10 条。
      for (var i = 0; i < 20; i++) {
        store.put(t0.add(Duration(seconds: i * 3)), {
          MetricField.cpuPct: i.toDouble(),
          if (i < 10) MetricField.cpuTemp: 40 + i.toDouble(),
        });
      }

      final points = store.series(
        fields: [MetricField.cpuPct, MetricField.cpuTemp],
        from: t0,
        to: t0.add(const Duration(seconds: 60)),
        buckets: 6,
      );

      // 每个桶 10 秒：0/3/6/9 秒一个，共 6 个桶。
      expect(points.length, 6);
      expect(points.first.time, t0);
      expect(points.last.time, t0.add(const Duration(seconds: 50)));
      expect(points.first[MetricField.cpuPct], closeTo(1.5, 0.001));
      expect(points.last[MetricField.cpuPct], closeTo(18, 0.001));
      // 温度只在前 10 条里，第三桶（30 秒起）就是空的。
      expect(points[0][MetricField.cpuTemp], closeTo(41.5, 0.001));
      expect(points[3][MetricField.cpuTemp], isNull);
      // 缺口不参与均值与峰值；它们数的是画出来的这些点，也就是桶的均值。
      expect(MetricPoint.mean(points, MetricField.cpuTemp),
          closeTo((41.5 + 45 + 48) / 3, 0.001));
      expect(MetricPoint.peak(points, MetricField.cpuTemp), 48);
      expect(MetricPoint.latest(points, MetricField.cpuTemp), 48);
    });

    test('桶数由窗口与桶数决定，窗口外的行不参与', () {
      store.put(t0.subtract(const Duration(days: 1)),
          {MetricField.cpuPct: 99});
      store.put(t0, {MetricField.cpuPct: 5});

      final points = store.series(
        fields: [MetricField.cpuPct],
        from: t0.subtract(const Duration(hours: 1)),
        to: t0.add(const Duration(hours: 1)),
        buckets: 4,
      );
      expect(points.length, lessThanOrEqualTo(4));
      expect(MetricPoint.peak(points, MetricField.cpuPct), 5);
      expect(points.first.time, t0, reason: '昨天那条不在窗口里，桶从今天这条起');
    });

    test('prune 只删窗口之前的，clear 一条不留', () {
      store.put(t0.subtract(const Duration(days: 8)), {MetricField.cpuPct: 1});
      store.put(t0.subtract(const Duration(days: 6)), {MetricField.cpuPct: 2});
      store.put(t0, {MetricField.cpuPct: 3});

      expect(store.prune(t0.subtract(const Duration(days: 7))), 1);
      expect(store.summary.count, 2);
      expect(store.summary.first, t0.subtract(const Duration(days: 6)));

      expect(store.clear(), 2);
      expect(store.summary.count, 0);
      expect(store.summary.first, isNull);
      expect(store.summary.last, isNull);
    });

    test('空表上读、扫、清都是安静的', () {
      expect(store.summary.count, 0);
      expect(store.summary.first, isNull);
      expect(
        store.series(
          fields: [MetricField.cpuPct],
          from: t0,
          to: t0.add(const Duration(hours: 1)),
        ),
        isEmpty,
      );
      expect(store.prune(t0), 0);
      expect(store.clear(), 0);
    });
  });

  group('MetricPoint 与 MetricField', () {
    test('均值、峰值、最新值都跳过缺口', () {
      final points = [
        MetricPoint(t0, {MetricField.cpuPct: 10, MetricField.cpuTemp: null}),
        MetricPoint(t0.add(const Duration(seconds: 3)),
            {MetricField.cpuPct: 30, MetricField.cpuTemp: 60}),
        MetricPoint(t0.add(const Duration(seconds: 6)),
            {MetricField.cpuPct: null, MetricField.cpuTemp: null}),
      ];

      expect(MetricPoint.mean(points, MetricField.cpuPct), 20);
      expect(MetricPoint.peak(points, MetricField.cpuPct), 30);
      expect(MetricPoint.latest(points, MetricField.cpuPct), 30);
      expect(MetricPoint.mean(points, MetricField.cpuTemp), 60);
      expect(MetricPoint.latest(points, MetricField.cpuTemp), 60);
      expect(MetricPoint.mean(const [], MetricField.cpuPct), isNull);
      expect(MetricPoint.peak(const [], MetricField.cpuPct), isNull);
      expect(MetricPoint.latest(const [], MetricField.cpuPct), isNull);
    });

    test('读数按字段自己的单位与小数位写出来', () {
      expect(MetricField.cpuPct.format(42.14), '42.1 %');
      expect(MetricField.cpuTemp.format(61.4), '61 °C');
      expect(MetricField.cpuFreqMhz.format(4800.2), '4800 MHz');
      expect(MetricField.netDownKbps.format(2048), '2048 KB/s');
      expect(MetricField.fanRpm.format(null), '—');
      // 百分比有天花板，网络速率与转速没有。
      expect(MetricField.cpuPct.ceiling, 100);
      expect(MetricField.memPct.ceiling, 100);
      expect(MetricField.diskPct.ceiling, 100);
      expect(MetricField.netUpKbps.ceiling, isNull);
      expect(MetricField.fanRpm.ceiling, isNull);
    });
  });
}
