import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/metric_database.dart';
import '../data/metric_store.dart';
import '../native/hwprobe_service.dart';
import 'app_activity.dart';

/// One collection's numbers, taken at the moment it is asked for.
typedef MetricSource = Map<MetricField, double?> Function();

/// The device history recorder: every [interval] it reads the machine once and
/// appends a row to the metrics database, keeping the last [retention] of
/// them.
///
/// It reads the probe's *current* readings on its own timer rather than
/// counting the probe's one-second ticks: the two rates are different
/// questions — the panel redraws at 1 Hz because a readout should look live,
/// while this writes at whatever the user asked for, and the readings in
/// between are the same numbers anyway.
class MetricsProvider extends ChangeNotifier {
  MetricsProvider({
    Directory? dataDir,
    DateTime Function()? clock,
  })  : _dataDirOverride = dataDir,
        _clock = clock ?? DateTime.now;

  final Directory? _dataDirOverride;
  MetricSource? _source;
  final DateTime Function() _clock;

  static Directory get _defaultDir {
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return Directory('$base\\XGameDesktop');
  }

  Directory get dataDir => _dataDirOverride ?? _defaultDir;

  /// What the app collects out of the box. The rates the settings page offers
  /// live with the setting — see `SettingsProvider.sampleIntervalChoices`.
  static const Duration defaultInterval = Duration(seconds: 3);

  /// How much history is kept. A week of three-second samples is ~200k rows,
  /// tens of megabytes of WAL churn, and a chart that still fits a phone-sized
  /// window once it is bucketed.
  static const Duration retention = Duration(days: 7);

  static const Duration minInterval = Duration(seconds: 1);
  static const Duration maxInterval = Duration(minutes: 5);

  /// How many collections between two retention sweeps: at the default rate
  /// this is ten minutes, and a sweep is one indexed delete.
  static const int pruneEvery = 200;

  Duration _interval = defaultInterval;
  Duration get interval => _interval;

  MetricDatabase? _db;
  MetricStore? _store;
  Timer? _timer;
  VoidCallback? _activityListener;
  bool _started = false;
  bool _closed = false;
  int _sincePrune = 0;

  /// Set by every write, sweep and clear: the figures below are read back out
  /// of the table on the next look rather than counted per collection, because
  /// `count(*)` walks the whole index and nobody is watching between two looks.
  bool _dirty = true;

  int _sampleCount = 0;
  DateTime? _firstSample;
  DateTime? _lastSample;

  /// How many readings the history holds, read back from the table when it has
  /// changed since the last look.
  int get sampleCount {
    _maybeRefresh();
    return _sampleCount;
  }

  /// The oldest and newest reading in the history, or null when there is none.
  DateTime? get firstSample {
    _maybeRefresh();
    return _firstSample;
  }

  DateTime? get lastSample {
    _maybeRefresh();
    return _lastSample;
  }

  /// How much history is kept — the page's "近 7 天".
  Duration get window => retention;

  /// The moment a collection is stamped with, in UTC. The page draws its
  /// windows against this rather than against a clock of its own, so a reading
  /// is never left out of the chart because two clocks disagree.
  DateTime get now => _clock().toUtc();

  /// Whether anything is being collected at all: a history that could not be
  /// opened leaves this false, and the page says so rather than showing an
  /// empty chart forever.
  bool get active => _started;

  /// The readings to record. The shell hands in the hardware probe's; a test
  /// hands in its own script.
  void attach(MetricSource source) => _source = source;

  /// Opens the history and starts collecting. Idempotent — the shell calls it
  /// once the settings have been read, since the rate is a setting.
  void start({Duration? interval}) {
    if (interval != null) setInterval(interval);
    if (_started) return;
    _started = true;
    try {
      final db = MetricDatabase.open(dataDir);
      _db = db;
      _store = db.store();
    } catch (_) {
      // A history that cannot be opened is a diagnostic that is not being
      // collected; the rest of the app has no business failing over it.
      _started = false;
      return;
    }
    _sweep();
    _watchActivity();
    // One reading now rather than one interval from now: the page opens on a
    // curve instead of on nothing.
    recordNow();
    _arm();
    notifyListeners();
  }

  /// Changes the collection rate. Called from the settings page's switch; the
  /// timer is re-armed on the spot, so the next reading follows the new rate.
  void setInterval(Duration value) {
    final next = _clamp(value);
    if (next == _interval) return;
    _interval = next;
    if (_started) _arm();
    notifyListeners();
  }

  static Duration _clamp(Duration value) {
    if (value < minInterval) return minInterval;
    if (value > maxInterval) return maxInterval;
    return value;
  }

  /// Records one reading now. The timer's whole job, and the seam the tests
  /// drive.
  void recordNow() {
    final store = _store;
    final source = _source;
    if (_closed || store == null || source == null) return;
    // The probe stands its own poll down while the window is hidden, so a
    // reading taken here would only write the same numbers again.
    if (!AppActivity.isVisible) return;

    final values = source();
    // Nothing at all available means the backend is not reporting — no
    // hwprobe.dll, a machine without the sensor, a driver the readings need.
    // A row of nulls would be a hole in the chart dressed up as a reading.
    if (values.values.every((value) => value == null)) return;

    try {
      store.put(_clock(), values);
    } catch (_) {
      return;
    }
    _dirty = true;
    _sincePrune++;
    if (_sincePrune >= pruneEvery) _sweep();
    notifyListeners();
  }

  /// Throws the whole history away — the page's 清空记录.
  void clear() {
    final store = _store;
    if (store == null) return;
    try {
      store.clear();
    } catch (_) {
      return;
    }
    _sincePrune = 0;
    _dirty = true;
    notifyListeners();
  }

  /// The window `[from, to]` reduced to at most [buckets] points, averaged per
  /// bucket. See [MetricStore.series].
  List<MetricPoint> series({
    required List<MetricField> fields,
    required DateTime from,
    required DateTime to,
    int buckets = 240,
  }) =>
      _store?.series(
        fields: fields,
        from: from,
        to: to,
        buckets: buckets,
      ) ??
      const [];

  /// Drops everything older than [retention].
  void _sweep() {
    _sincePrune = 0;
    try {
      _store?.prune(_clock().toUtc().subtract(retention));
    } catch (_) {}
    _dirty = true;
  }

  void _maybeRefresh() {
    if (!_dirty) return;
    _dirty = false;
    final store = _store;
    if (store == null) return;
    try {
      final summary = store.summary;
      _sampleCount = summary.count;
      _firstSample = summary.first;
      _lastSample = summary.last;
    } catch (_) {}
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => recordNow());
  }

  /// Stands the timer down while the window is hidden and brings it back with
  /// a reading on the way in, on the probe's own terms — the readings cannot
  /// move while the probe is not polling, and a chart that resumes a whole
  /// interval late reads as a gap that never happened.
  void _watchActivity() {
    _activityListener ??= () {
      if (!AppActivity.isVisible) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      if (!_started || _closed) return;
      recordNow();
      _arm();
    };
    AppActivity.visible.removeListener(_activityListener!);
    AppActivity.visible.addListener(_activityListener!);
  }

  /// The readings this app collects, as the hardware probe holds them.
  ///
  /// The disk and fan lists are folded to one number each rather than recorded
  /// per device: the question the chart answers is "is the machine busy", and
  /// a machine with three disks and six fans would otherwise spend a week's
  /// rows on values nobody draws separately. The busiest disk and the fastest
  /// fan are that answer; the panel still lists them one by one.
  static MetricSource probeSource(HwprobeService probe) => () => {
        MetricField.cpuPct: probe.cpuUsage,
        MetricField.cpuTemp: probe.cpuTemp,
        MetricField.cpuFreqMhz: probe.cpuFreqMhz,
        MetricField.cpuPowerW: probe.cpuPowerW,
        MetricField.gpuPct: probe.gpuUsage,
        MetricField.gpuTemp: probe.gpuTemp,
        MetricField.gpuPowerW: probe.gpuPowerW,
        MetricField.gpuMemMb: probe.gpuMemUsedMb,
        MetricField.memPct: probe.memoryUsagePct,
        MetricField.memUsedMb: probe.memoryUsedMb,
        MetricField.memPowerW: probe.memoryPowerW,
        MetricField.diskPct: _busiestDisk(probe),
        MetricField.diskReadKbps:
            _totalDisk(probe, (i) => probe.diskReadKbps(i)),
        MetricField.diskWriteKbps:
            _totalDisk(probe, (i) => probe.diskWriteKbps(i)),
        MetricField.netDownKbps: probe.downloadKbps,
        MetricField.netUpKbps: probe.uploadKbps,
        MetricField.fanRpm: _fastestFan(probe),
      };

  static double? _busiestDisk(HwprobeService probe) {
    double? best;
    for (var i = 0; i < probe.disks.length; i++) {
      final value = probe.diskActivity(i);
      if (value == null) continue;
      if (best == null || value > best) best = value;
    }
    return best;
  }

  static double? _totalDisk(HwprobeService probe, double? Function(int) read) {
    var sum = 0.0;
    var seen = false;
    for (var i = 0; i < probe.disks.length; i++) {
      final value = read(i);
      if (value == null) continue;
      sum += value;
      seen = true;
    }
    return seen ? sum : null;
  }

  static double? _fastestFan(HwprobeService probe) {
    double? best;
    for (final fan in probe.fanReadings) {
      final value = fan.rpm;
      if (value == null) continue;
      if (best == null || value > best) best = value;
    }
    return best;
  }

  @override
  void dispose() {
    // Idempotent: the database goes with the provider, and a caller that
    // releases it early — a test, or a screen torn down by hand — must not
    // turn a second release into an error.
    if (_closed) return;
    _closed = true;
    _started = false;
    _timer?.cancel();
    _timer = null;
    final listener = _activityListener;
    if (listener != null) AppActivity.visible.removeListener(listener);
    _activityListener = null;
    _store = null;
    _db?.close();
    _db = null;
    super.dispose();
  }
}
