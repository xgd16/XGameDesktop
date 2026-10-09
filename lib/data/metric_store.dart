import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart';

/// One collected reading of the machine: the column it lives in, how it reads
/// in the UI, and the ceiling a chart draws it against.
///
/// The enum is the single place a reading is named: the table the
/// [MetricDatabase] creates, the write, the bucketed read and the charts all
/// walk it, so a column cannot drift away from the chart that draws it. A
/// percentage is pinned to [ceiling]; everything else autoscales, because a
/// network rate or a fan speed has no honest maximum.
enum MetricField {
  cpuPct('cpu_pct', 'CPU 占用率', '%', ceiling: 100, decimals: 1),
  cpuTemp('cpu_temp', 'CPU 温度', '°C', decimals: 0),
  cpuFreqMhz('cpu_freq_mhz', 'CPU 频率', 'MHz', decimals: 0),
  cpuPowerW('cpu_power_w', 'CPU 功耗', 'W', decimals: 1),
  gpuPct('gpu_pct', 'GPU 占用率', '%', ceiling: 100, decimals: 1),
  gpuTemp('gpu_temp', 'GPU 温度', '°C', decimals: 0),
  gpuPowerW('gpu_power_w', 'GPU 功耗', 'W', decimals: 1),
  gpuMemMb('gpu_mem_mb', '显存用量', 'MB', decimals: 0),
  memPct('mem_pct', '内存占用率', '%', ceiling: 100, decimals: 1),
  memUsedMb('mem_used_mb', '内存用量', 'MB', decimals: 0),
  memPowerW('mem_power_w', '内存功耗', 'W', decimals: 1),
  diskPct('disk_pct', '磁盘活动', '%', ceiling: 100, decimals: 0),
  diskReadKbps('disk_read_kbps', '磁盘读取', 'KB/s', decimals: 0),
  diskWriteKbps('disk_write_kbps', '磁盘写入', 'KB/s', decimals: 0),
  netDownKbps('net_down_kbps', '下行', 'KB/s', decimals: 0),
  netUpKbps('net_up_kbps', '上行', 'KB/s', decimals: 0),
  fanRpm('fan_rpm', '风扇转速', 'RPM', decimals: 0);

  const MetricField(
    this.column,
    this.label,
    this.unit, {
    this.ceiling,
    this.decimals = 1,
  });

  /// The `metric_sample` column this reading is stored in.
  final String column;

  /// What the chart card calls it.
  final String label;

  /// The unit its values are in — one unit per field, so a chart never mixes
  /// two scales on one axis.
  final String unit;

  /// The value the axis tops out at, when the reading has a natural one.
  /// Null autoscales to the data.
  final double? ceiling;

  /// How many decimals a readout of this field carries.
  final int decimals;

  /// [value] the way this field's readout reads — `42.1 %`, `61 °C`, `2048
  /// KB/s` — and `—` when there is nothing to show.
  String format(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(decimals)} $unit';
}

/// One point of a chart.
///
/// Written by [MetricStore.put] it is one collection — the readings as the
/// probe held them at [time]. Out of [MetricStore.series] it is one bucket:
/// every sample in a slice of the window, averaged, with [time] the bucket's
/// start. A field that no sample in the bucket reported stays null, and the
/// chart draws a gap there rather than a line through it.
class MetricPoint {
  MetricPoint(this.time, this.values);

  /// UTC.
  final DateTime time;

  final Map<MetricField, double?> values;

  double? operator [](MetricField field) => values[field];

  /// The field's last reported value in [points], or null when it never
  /// reported one.
  ///
  /// The three statistics here describe the points they are handed, which for
  /// a chart means the drawn buckets: the peak of a seven-day curve is the
  /// highest *bucket*, not the highest sample that went into one.
  static double? latest(List<MetricPoint> points, MetricField field) {
    for (var i = points.length - 1; i >= 0; i--) {
      final value = points[i][field];
      if (value != null) return value;
    }
    return null;
  }

  /// The field's average over [points] — nulls left out, so a value the driver
  /// never reported does not drag it down. Null when there is nothing at all.
  static double? mean(List<MetricPoint> points, MetricField field) {
    var sum = 0.0;
    var seen = 0;
    for (final point in points) {
      final value = point[field];
      if (value == null) continue;
      sum += value;
      seen++;
    }
    return seen == 0 ? null : sum / seen;
  }

  /// The field's largest value over [points], or null when it never reported
  /// one.
  static double? peak(List<MetricPoint> points, MetricField field) {
    double? best;
    for (final point in points) {
      final value = point[field];
      if (value == null) continue;
      if (best == null || value > best) best = value;
    }
    return best;
  }
}

/// The `metric_sample` table: one row per collection, one column per
/// [MetricField], and the row's own moment as its key.
///
/// Time is the primary key rather than a serial id: every read here is a
/// window of time, and the key therefore *is* the index those reads want — the
/// newest rows, the range between two moments, and the buckets a chart is
/// drawn from, all off one ordered scan.
class MetricStore {
  MetricStore(this._db);

  /// The table this store reads and writes.
  static const String table = 'metric_sample';

  /// The columns, in the order every read in here walks them.
  static final List<String> columns = [
    for (final field in MetricField.values) field.column,
  ];

  final Database _db;

  /// Writes one collection at [time].
  ///
  /// An absolute write, like every other store here: a sample that lands on a
  /// moment already in the table replaces it instead of failing, so a clock
  /// that has not moved — or a test that collects twice in the same
  /// millisecond — costs a row, not an exception.
  void put(DateTime time, Map<MetricField, double?> values) {
    final columns = MetricStore.columns;
    final assignments =
        [for (final column in columns) '$column = excluded.$column'].join(', ');
    _db.execute(
      'INSERT INTO $table (ts, ${columns.join(', ')}) '
      'VALUES (?, ${List.filled(columns.length, '?').join(', ')}) '
      'ON CONFLICT(ts) DO UPDATE SET $assignments',
      [
        time.toUtc().millisecondsSinceEpoch,
        // STRICT REAL columns take a double and nothing else.
        for (final field in MetricField.values) values[field]?.toDouble(),
      ],
    );
  }

  /// The window `[from, to]` reduced to at most [buckets] points, each the
  /// average of the samples that fell in it.
  ///
  /// A chart of a week of three-second samples is two hundred thousand points
  /// wide and a few hundred pixels across, so the reduction happens in SQLite
  /// — one scan of the window however many fields are asked for, which is why
  /// the charts page asks for every field it draws in one call.
  ///
  /// The bucket's timestamp is its start, and a bucket no sample landed in
  /// simply has no row: the caller sees the gap.
  List<MetricPoint> series({
    required List<MetricField> fields,
    required DateTime from,
    required DateTime to,
    int buckets = 240,
  }) {
    if (fields.isEmpty || buckets < 1) return const [];
    final span = to.difference(from).inMilliseconds;
    if (span <= 0) return const [];
    final width = math.max(1, (span / buckets).ceil());
    final averages =
        [for (final field in fields) 'avg(${field.column}) AS ${field.column}']
            .join(', ');
    final rows = _db.select(
      'SELECT (ts / ?) * ? AS bucket, $averages FROM $table '
      'WHERE ts >= ? AND ts <= ? GROUP BY bucket ORDER BY bucket',
      [
        width,
        width,
        from.toUtc().millisecondsSinceEpoch,
        to.toUtc().millisecondsSinceEpoch,
      ],
    );
    return [
      for (final row in rows)
        MetricPoint(
          DateTime.fromMillisecondsSinceEpoch(row['bucket'] as int,
              isUtc: true),
          {
            for (final field in fields)
              field: (row[field.column] as num?)?.toDouble(),
          },
        ),
    ];
  }

  /// What the history holds: how many samples, and the oldest and newest of
  /// them. One query for all three — the page's header shows every part of it.
  ({int count, DateTime? first, DateTime? last}) get summary {
    final row =
        _db.select('SELECT count(*) AS n, min(ts) AS first, max(ts) AS last '
            'FROM $table').first;
    return (
      count: row['n'] as int,
      first: _time(row['first'] as int?),
      last: _time(row['last'] as int?),
    );
  }

  /// Drops every sample older than [before]. Returns how many went.
  int prune(DateTime before) {
    _db.execute('DELETE FROM $table WHERE ts < ?',
        [before.toUtc().millisecondsSinceEpoch]);
    return _db.updatedRows;
  }

  /// Drops the whole history. Returns how many samples went.
  int clear() {
    _db.execute('DELETE FROM $table');
    return _db.updatedRows;
  }

  static DateTime? _time(int? millis) => millis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
}
