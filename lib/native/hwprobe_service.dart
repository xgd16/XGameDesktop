import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform, exit, sleep;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../state/app_activity.dart';
import 'hwprobe_bindings.dart';
import 'smbios_memory.dart';
import 'volumes.dart';
import 'win32_api.dart';

enum HwprobeStatus { loading, ready, backendMissing, initFailed }

/// A sensor we care about, addressed by its (category, device, sensor) triple.
class SensorRef {
  const SensorRef(this.category, this.device, this.sensor,
      {required this.code, required this.name, required this.unit});

  final int category;
  final int device;
  final int sensor;
  final String code;
  final String name;
  final String unit;
}

class DiskRef {
  DiskRef({
    required this.model,
    required this.mediaType,
    required this.busType,
    required this.capacityGb,
    this.activity,
    this.readRate,
    this.writeRate,
    this.temperature,
  });

  final String model;
  final String mediaType;
  final String busType;
  final double capacityGb;
  final SensorRef? activity;
  final SensorRef? readRate;
  final SensorRef? writeRate;
  final SensorRef? temperature;
}

class NetRef {
  NetRef({
    required this.name,
    this.rxRate,
    this.txRate,
    this.linkUp,
    this.linkSpeed,
  });

  final String name;
  final SensorRef? rxRate;
  final SensorRef? txRate;
  final SensorRef? linkUp;
  final SensorRef? linkSpeed;
}

/// One fan reading. Fans are discovered by unit, not by code: whichever
/// device exposes one — the GPU today, the board's SuperIO once the kernel
/// driver is in — calls it something else, but it always measures RPM.
class FanRef {
  FanRef({required this.device, required this.sensorName, required this.ref});

  /// The device the fan hangs off ("AMD Radeon RX 6800 XT", the board…).
  final String device;

  /// The sensor's own name ("Fan", "CPU Fan", …).
  final String sensorName;
  final SensorRef ref;
}

/// What one fan has shown so far — the two facts its row lives or dies by (see
/// [HwprobeService.fanReadings]). A board numbers every header whether a fan
/// hangs on it or not: one that never turned is not a fan to show, and one
/// that turned keeps its row through whatever the sensor fails to report
/// afterwards.
class _FanTrace {
  /// The last speed the sensor actually reported. Held across samples that
  /// come back empty — a vanishing reading is a sensor hiccup, not a fan
  /// change, and the row should not blink because of one.
  double? lastRpm;

  /// The fan has been seen turning (a reading above zero) at least once.
  bool spun = false;
}

/// Battery telemetry. Desktops expose no battery device at all — a null
/// [HwprobeService.battery] is the "hide the section" signal for the UI.
class BatteryRef {
  BatteryRef({
    required this.name,
    required this.chargePct,
    required this.state,
    this.rateMw,
    this.healthPct,
    this.cycleCount,
  });

  final String name;
  final SensorRef chargePct;
  final SensorRef state;

  /// mW, batclass 原始符号:正=放电、负=充电(见 [batteryRateW] 归一化)。
  final SensorRef? rateMw;

  // Static (read once at probe time).
  final double? healthPct;
  final int? cycleCount;
}

class _EnumerateResult {
  _EnumerateResult({required this.ok, this.error = ''});

  final bool ok;
  final String error;

  String cpuName = '';
  String cpuBrand = '';
  int cpuCores = 0;
  int cpuLogical = 0;
  String gpuName = '';
  String gpuDriver = '';
  String boardName = '';

  SensorRef? cpuLoad;
  SensorRef? cpuTemp;
  SensorRef? cpuPower;
  List<SensorRef> cpuFreqRefs = [];
  SensorRef? memUsed;
  SensorRef? memAvailable;
  SensorRef? memUsedPct;
  SensorRef? memPower;
  SensorRef? gpuUtil;
  SensorRef? gpuTemp;
  SensorRef? gpuPower;
  SensorRef? gpuMemUsed;
  SensorRef? gpuMemTotal;
  final List<DiskRef> disks = [];
  final List<NetRef> nets = [];
  final List<FanRef> fans = [];
  BatteryRef? battery;
}

/// FFI lifecycle for hwprobe.dll plus the live readings snapshot consumed by
/// the UI. Subscribes at 1 Hz and notifies listeners on every batch.
class HwprobeService extends ChangeNotifier {
  HwprobeStatus status = HwprobeStatus.loading;
  String initError = '';

  /// Which utilization sampling the backend uses right now —
  /// [usageModeStandard] (default) or [usageModeTaskManager]. Written by
  /// [setUsageMode]; the DLL applies it to its next refresh (≤1 s).
  int usageMode = usageModeStandard;

  // Static tree (filled once after init).
  String cpuName = '';
  String cpuBrand = '';
  int cpuCores = 0;
  int cpuLogical = 0;
  String gpuName = '';
  String gpuDriver = '';
  String boardName = '';

  /// e.g. "DDR4 · 3000 MT/s · 2 条" — read from SMBIOS once at startup.
  String memoryDesc = '';

  SensorRef? _cpuLoad;
  SensorRef? _cpuTemp;
  SensorRef? _cpuPower;
  List<SensorRef> _cpuFreqRefs = const [];
  SensorRef? _memUsed;
  SensorRef? _memAvailable;
  SensorRef? _memUsedPct;
  SensorRef? _memPower;
  SensorRef? _gpuUtil;
  SensorRef? _gpuTemp;
  SensorRef? _gpuPower;
  SensorRef? _gpuMemUsed;
  SensorRef? _gpuMemTotal;
  List<DiskRef> disks = const [];
  List<NetRef> nets = const [];

  /// A fresh set of fans is a fresh set of rows: what each has shown so far
  /// (the traces) belongs to the sensors they were collected against.
  List<FanRef> _fans = const [];
  List<FanRef> get fans => _fans;
  set fans(List<FanRef> value) {
    _fans = value;
    _fanTrace.clear();
  }

  /// Per-fan bookkeeping, keyed by its place in [fans].
  final Map<int, _FanTrace> _fanTrace = {};

  List<VolumeInfo> volumes = const [];
  BatteryRef? battery;

  final Map<(int, int, int), HwprobeReadingValue> _readings = {};
  final Map<String, List<double>> history = {};

  HwprobeBindings? _bindings;

  /// Native scratch for one reading. Allocated on first use and freed exactly
  /// once: the exit hook tears the probe down after [restartAsAdmin] may
  /// already have, and a second free of the same pointer is a crash.
  Pointer<HwprobeReading>? _readingBuf;
  Timer? _pollTimer;
  bool _shuttingDown = false;

  Pointer<HwprobeReading> _readingBuffer() => _readingBuf ??= calloc();

  void _freeReadingBuffer() {
    final buffer = _readingBuf;
    _readingBuf = null;
    if (buffer != null) calloc.free(buffer);
  }

  String get _dllPath {
    final exe = Platform.resolvedExecutable;
    final dir = exe.substring(0, exe.lastIndexOf('\\'));
    return '$dir\\hwprobe.dll';
  }

  Future<void> start() async {
    // The failure paths below are retried from the panel's button, so a failed
    // start has to leave the door open — but two starts running at once would
    // leave two poll timers behind, and a third would leak another one.
    if (_starting) return;
    _starting = true;
    try {
      await _startOnce();
    } finally {
      _starting = false;
    }
  }

  bool _starting = false;

  Future<void> _startOnce() async {
    // Cheap availability probe on the main isolate (open + abi check).
    try {
      final b = HwprobeBindings.load();
      if (b.abiVersion != hwprobeAbiVersion) {
        status = HwprobeStatus.backendMissing;
        initError = 'ABI 版本不匹配 (得到 ${b.abiVersion},需要 $hwprobeAbiVersion)';
        notifyListeners();
        return;
      }
      _bindings = b;
    } catch (_) {
      status = HwprobeStatus.backendMissing;
      initError = '监控后端未加载,请确认 hwprobe.dll 与应用同目录';
      notifyListeners();
      return;
    }

    final path = _dllPath;
    final result = await Isolate.run(() => _initAndEnumerate(path));
    if (!result.ok) {
      status = HwprobeStatus.initFailed;
      initError = result.error;
      notifyListeners();
      return;
    }

    cpuName = result.cpuName;
    cpuBrand = result.cpuBrand;
    cpuCores = result.cpuCores;
    cpuLogical = result.cpuLogical;
    gpuName = result.gpuName;
    gpuDriver = result.gpuDriver;
    boardName = result.boardName;
    memoryDesc = memoryModulesSummary(readMemoryModules());
    _cpuLoad = result.cpuLoad;
    _cpuTemp = result.cpuTemp;
    _cpuPower = result.cpuPower;
    _cpuFreqRefs = result.cpuFreqRefs;
    _memUsed = result.memUsed;
    _memAvailable = result.memAvailable;
    _memUsedPct = result.memUsedPct;
    _memPower = result.memPower;
    _gpuUtil = result.gpuUtil;
    _gpuTemp = result.gpuTemp;
    _gpuPower = result.gpuPower;
    _gpuMemUsed = result.gpuMemUsed;
    _gpuMemTotal = result.gpuMemTotal;
    disks = result.disks;
    nets = result.nets;
    fans = result.fans;
    battery = result.battery;

    status = HwprobeStatus.ready;
    notifyListeners();
    _watchActivity();
    if (AppActivity.isVisible) _startPolling();
  }

  /// Runs on a worker isolate: init blocks for 1–2 s on first launch, and the
  /// DLL keeps its global state (and polling thread) alive afterwards.
  static _EnumerateResult _initAndEnumerate(String dllPath) {
    try {
      final b = HwprobeBindings.load(explicitPath: dllPath);
      final rc = b.init();
      if (rc != statusOk && rc != statusWaiting) {
        return _EnumerateResult(ok: false, error: '初始化失败 (rc=$rc)');
      }

      // Wait until the tree is populated (first refresh completes).
      final countBuf = calloc<Uint32>();
      var categories = 0;
      for (var i = 0; i < 50; i++) {
        sleep(const Duration(milliseconds: 100));
        final rc = b.getCategoryCount(countBuf);
        if (rc == statusOk && countBuf.value > 0) {
          categories = countBuf.value;
          break;
        }
      }
      if (categories == 0) {
        calloc.free(countBuf);
        return _EnumerateResult(ok: false, error: '等待传感器数据超时');
      }
      calloc.free(countBuf);
      return _enumerate(b);
    } catch (e) {
      return _EnumerateResult(ok: false, error: '监控后端异常: $e');
    }
  }

  static _EnumerateResult _enumerate(HwprobeBindings b) {
    final r = _EnumerateResult(ok: true);
    final catCount = calloc<Uint32>();
    if (b.getCategoryCount(catCount) != statusOk) {
      calloc.free(catCount);
      return _EnumerateResult(ok: false, error: '枚举硬件分类失败');
    }

    for (var c = 0; c < catCount.value; c++) {
      final cat = calloc<HwprobeCategoryInfo>();
      cat.ref.size = sizeOf<HwprobeCategoryInfo>();
      if (b.getCategoryInfo(c, cat) != statusOk) {
        calloc.free(cat);
        continue;
      }
      final deviceCount = cat.ref.deviceCount;
      calloc.free(cat);

      for (var d = 0; d < deviceCount; d++) {
        final dev = calloc<HwprobeDeviceInfo>();
        dev.ref.size = sizeOf<HwprobeDeviceInfo>();
        if (b.getDeviceInfo(c, d, dev) != statusOk) {
          calloc.free(dev);
          continue;
        }
        final devName = dev.ref.nameText;
        calloc.free(dev);

        final sensors = <String, SensorRef>{};
        final staticValues = <String, (double, String)>{};
        final senCount = calloc<Uint32>();
        if (b.getSensorCount(c, d, senCount) == statusOk) {
          for (var s = 0; s < senCount.value; s++) {
            final sen = calloc<HwprobeSensorInfo>();
            sen.ref.size = sizeOf<HwprobeSensorInfo>();
            if (b.getSensorInfo(c, d, s, sen) != statusOk) {
              calloc.free(sen);
              continue;
            }
            final info = sen.ref;
            final ref = SensorRef(c, d, s,
                code: info.codeText,
                name: info.nameText,
                unit: info.unitText);
            sensors[ref.code] = ref;

            // Static sensors never appear in stream batches — read once.
            if (info.kind == sensorKindStatic) {
              final reading = calloc<HwprobeReading>();
              reading.ref.size = sizeOf<HwprobeReading>();
              if (b.readSensor(c, d, s, reading) == statusOk) {
                final rd = reading.ref;
                if (rd.status == statusOk) {
                  staticValues[ref.code] =
                      (rd.doubleValue, rd.stringValue);
                }
              }
              calloc.free(reading);
            }
            calloc.free(sen);
          }
        }
        calloc.free(senCount);

        // Fans by unit, wherever they turn up — the GPU's tachometer needs no
        // kernel driver, the board's does, and neither agrees on a code.
        for (final ref in sensors.values) {
          if (ref.unit.toLowerCase() == 'rpm') {
            r.fans.add(FanRef(device: devName, sensorName: ref.name, ref: ref));
          }
        }

        switch (c) {
          case catCpu:
            _collectCpu(devName, sensors, staticValues, r);
          case catMemory:
            // 该分类下有多个设备(DIMM 等),只有 "Physical Memory" 带占用
            // 传感器;用 ??= 防止后面的设备把已有引用覆盖成 null。
            r.memUsed ??= sensors['used_mb'];
            r.memAvailable ??= sensors['available_mb'];
            r.memUsedPct ??= sensors['used_pct'];
            r.memPower ??= sensors['power_dram'];
          case catGpu:
            if (r.gpuName.isEmpty) {
              _collectGpu(devName, sensors, staticValues, r);
            }
          case catMotherboard:
            // Handhelds expose a second "Embedded Controller (EC)" device
            // here (ABI 3); keep the actual board name, not the EC.
            if (r.boardName.isEmpty) {
              r.boardName = devName;
            }
          case catDisk:
            r.disks.add(_collectDisk(devName, sensors, staticValues));
          case catNetwork:
            r.nets.add(_collectNet(devName, sensors));
          case catBattery:
            // Handhelds/laptops have one battery device; desktops have none.
            r.battery ??= _collectBattery(devName, sensors, staticValues);
        }
      }
    }
    calloc.free(catCount);
    return r;
  }

  static void _collectCpu(
      String devName,
      Map<String, SensorRef> sensors,
      Map<String, (double, String)> statics,
      _EnumerateResult r) {
    r.cpuName = devName;
    r.cpuBrand = statics['brand']?.$2 ?? '';
    r.cpuCores = statics['cores']?.$1.toInt() ?? 0;
    r.cpuLogical = statics['logical']?.$1.toInt() ?? 0;
    r.cpuLoad = sensors['load_total'];
    r.cpuTemp = _firstTempSensor(sensors);
    r.cpuPower = sensors['power_pkg'];
    final freqs = sensors.keys
        .where((k) => k.startsWith('freq_core_'))
        .map((k) => sensors[k]!)
        .toList()
      ..sort((a, b) => a.code.compareTo(b.code));
    r.cpuFreqRefs = freqs;
  }

  static SensorRef? _firstTempSensor(Map<String, SensorRef> sensors) {
    for (final s in sensors.values) {
      if (s.unit == '°C') return s;
    }
    return null;
  }

  static void _collectGpu(
      String devName,
      Map<String, SensorRef> sensors,
      Map<String, (double, String)> statics,
      _EnumerateResult r) {
    r.gpuName = devName;
    r.gpuDriver = statics['driver_version']?.$2 ?? '';
    r.gpuUtil = sensors['util_gpu_pct'];
    r.gpuTemp = sensors['temperature_c'] ?? _firstTempSensor(sensors);
    r.gpuPower = sensors['power_w'];
    r.gpuMemUsed = sensors['mem_used_mb'];
    r.gpuMemTotal = sensors['vram_total_mb'];
  }

  static DiskRef _collectDisk(
      String devName,
      Map<String, SensorRef> sensors,
      Map<String, (double, String)> statics) {
    return DiskRef(
      model: devName,
      mediaType: statics['media_type']?.$2 ?? '',
      busType: statics['bus_type']?.$2 ?? '',
      capacityGb: statics['capacity_gb']?.$1 ?? 0,
      activity: sensors['activity_pct'],
      readRate: sensors['read_kbps'],
      writeRate: sensors['write_kbps'],
      temperature: sensors['temperature_c'],
    );
  }

  static NetRef _collectNet(String devName, Map<String, SensorRef> sensors) {
    return NetRef(
      name: devName,
      rxRate: sensors['rx_kbps'],
      txRate: sensors['tx_kbps'],
      linkUp: sensors['link_up'],
      linkSpeed: sensors['link_speed_mbps'],
    );
  }

  /// Null when the device lacks the sensors a useful section needs — then the
  /// UI hides it instead of showing a shell with nothing but '--'.
  static BatteryRef? _collectBattery(
      String devName,
      Map<String, SensorRef> sensors,
      Map<String, (double, String)> statics) {
    final charge = sensors['charge_pct'];
    final state = sensors['state'];
    if (charge == null || state == null) return null;
    return BatteryRef(
      name: devName,
      chargePct: charge,
      state: state,
      rateMw: sensors['rate_mw'],
      healthPct: statics['health_pct']?.$1,
      cycleCount: statics['cycle_count']?.$1.toInt(),
    );
  }

  /// Pull mode: hwprobe_read_sensor copies from the DLL's internal cache and
  /// is safe to call from any thread. (The subscribe callback hands out a
  /// batch pointer that is only valid during the native invocation, which
  /// Dart's async NativeCallable.listener cannot honor.)
  void _startPolling() {
    if (_pollTimer != null) return;
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  /// Stands the poll down while the window is hidden and brings it back with a
  /// fresh reading on the way in. Called once from [start]; the listener lives
  /// as long as the service.
  void _watchActivity() {
    _activityListener ??= () {
      if (!AppActivity.isVisible) {
        _pollTimer?.cancel();
        _pollTimer = null;
        return;
      }
      if (status == HwprobeStatus.ready && !_shuttingDown) _startPolling();
    };
    AppActivity.visible.removeListener(_activityListener!);
    AppActivity.visible.addListener(_activityListener!);
  }

  VoidCallback? _activityListener;

  /// Ticks between full volume re-enumerations. The static parts of a volume
  /// (letter, label, total) are re-read rarely, and the free space every tick.
  static const _volumeRescanTicks = 30;
  int _volumeTick = 0;

  void _poll() {
    if (_shuttingDown) return;
    final b = _bindings;
    if (b == null) return;

    final buf = _readingBuffer();
    buf.ref.size = sizeOf<HwprobeReading>();
    void read(SensorRef? ref) {
      if (ref == null) return;
      final rc = b.readSensor(ref.category, ref.device, ref.sensor, buf);
      if (rc != statusOk) return;
      final rd = buf.ref;
      // Only a string reading needs its text decoded: decodeFixedString walks
      // up to 96 bytes through FFI, one load each, and the numeric sensors —
      // which is nearly all of them — never look at it.
      final isText = rd.valueType == vtypeString;
      _readings[(ref.category, ref.device, ref.sensor)] = HwprobeReadingValue(
        status: rd.status,
        timestampMs: rd.timestampMs,
        valueType: rd.valueType,
        f64: rd.value.f64,
        u64: rd.value.u64,
        i64: rd.value.i64,
        b: rd.value.b,
        s: isText ? rd.value.sText : '',
      );
    }

    read(_cpuLoad);
    read(_cpuTemp);
    read(_cpuPower);
    for (final ref in _cpuFreqRefs) {
      read(ref);
    }
    read(_memUsed);
    read(_memAvailable);
    read(_memUsedPct);
    read(_memPower);
    read(_gpuUtil);
    read(_gpuTemp);
    read(_gpuPower);
    read(_gpuMemUsed);
    read(_gpuMemTotal);
    for (var i = 0; i < fans.length; i++) {
      read(fans[i].ref);
      _traceFan(i, _doubleValue(fans[i].ref));
    }
    for (final disk in disks) {
      read(disk.activity);
      read(disk.readRate);
      read(disk.writeRate);
      read(disk.temperature);
    }
    for (final net in nets) {
      read(net.rxRate);
      read(net.txRate);
      read(net.linkUp);
      read(net.linkSpeed);
    }
    final bat = battery;
    if (bat != null) {
      read(bat.chargePct);
      read(bat.state);
      read(bat.rateMw);
    }

    // Volume usage comes from the OS, not from hwprobe. Only the free space is
    // re-read per tick; the drive list itself is re-enumerated rarely, because
    // that is what costs a volume-information call per drive.
    if (volumes.isEmpty || _volumeTick++ >= _volumeRescanTicks) {
      _volumeTick = 0;
      volumes = listFixedVolumes();
    } else {
      volumes = refreshVolumeUsage(volumes);
    }

    _pushHistory();
    notifyListeners();
  }

  void _pushHistory() {
    void push(String key, double? v) {
      if (v == null) return;
      final list = history.putIfAbsent(key, () => []);
      list.add(v);
      if (list.length > 90) list.removeRange(0, list.length - 90);
    }

    push('cpu', cpuUsage);
    push('gpu', gpuUsage);
    push('mem', memoryUsagePct);
    push('down', downloadKbps);
    push('up', uploadKbps);
    for (var i = 0; i < disks.length && i < 4; i++) {
      push('disk$i', diskActivity(i));
    }
  }

  // ---- typed live getters (null = unavailable) ----

  double? _doubleValue(SensorRef? ref) {
    if (ref == null) return null;
    final v = _readings[(ref.category, ref.device, ref.sensor)];
    if (v == null || v.status != statusOk) return null;
    return v.asDouble;
  }

  HwprobeReadingValue? rawValue(SensorRef? ref) {
    if (ref == null) return null;
    return _readings[(ref.category, ref.device, ref.sensor)];
  }

  double? get cpuUsage => _doubleValue(_cpuLoad);
  double? get cpuTemp => _doubleValue(_cpuTemp);

  /// CPU package power (RAPL); only present with the kernel driver + admin.
  double? get cpuPowerW => _doubleValue(_cpuPower);

  double? get cpuFreqMhz {
    double? max;
    for (final ref in _cpuFreqRefs) {
      final v = _doubleValue(ref);
      if (v != null && (max == null || v > max)) max = v;
    }
    return max;
  }

  double? get memoryUsedMb => _doubleValue(_memUsed);
  double? get memoryAvailableMb => _doubleValue(_memAvailable);

  double? get memoryUsagePct {
    final pct = _doubleValue(_memUsedPct);
    if (pct != null) return pct;
    final used = memoryUsedMb;
    final avail = memoryAvailableMb;
    if (used != null && avail != null && used + avail > 0) {
      return used / (used + avail) * 100;
    }
    return null;
  }

  double? get memoryTotalMb {
    final used = memoryUsedMb;
    final avail = memoryAvailableMb;
    if (used != null && avail != null) return used + avail;
    return null;
  }

  /// RAPL DRAM domain power (memory power); needs the kernel driver + admin
  /// and a CPU that exposes the domain.
  double? get memoryPowerW => _doubleValue(_memPower);

  double? get gpuUsage => _doubleValue(_gpuUtil);
  double? get gpuTemp => _doubleValue(_gpuTemp);
  double? get gpuPowerW => _doubleValue(_gpuPower);
  double? get gpuMemUsedMb => _doubleValue(_gpuMemUsed);
  double? get gpuMemTotalMb => _doubleValue(_gpuMemTotal);

  /// The fan rows worth showing, in enumeration order, each with the label the
  /// panel shows and the last speed it reported. A board numbers every header
  /// whether a fan hangs on it or not, so a row is earned by turning: one that
  /// only ever reads zero (an empty header) or nothing (no tachometer wire)
  /// takes no row once the samples say so. One that has turned keeps its row
  /// for good and holds its last speed across samples that come back empty —
  /// the readings blink on some boards, the list should not.
  ///
  /// A sensor called just "Fan" says nothing about where it hangs once
  /// two devices both expose one, so repeated labels carry the device name.
  List<({String label, String device, double? rpm})> get fanReadings {
    if (fans.isEmpty) return const [];
    final rows = [
      for (var i = 0; i < fans.length; i++)
        if (_fanRowVisible(i)) (i: i, label: _fanLabel(fans[i])),
    ];
    final seen = <String, int>{};
    for (final row in rows) {
      seen[row.label] = (seen[row.label] ?? 0) + 1;
    }
    return [
      for (final row in rows)
        (
          label: seen[row.label]! > 1
              ? '${row.label} · ${fans[row.i].device}'
              : row.label,
          device: fans[row.i].device,
          rpm: _fanTrace[row.i]?.lastRpm,
        )
    ];
  }

  /// Whether the panel owes this fan a row: one that has turned keeps it, and
  /// one nobody has sampled yet gets the benefit of the doubt (a '--' row
  /// until the first sample says otherwise).
  bool _fanRowVisible(int i) {
    final trace = _fanTrace[i];
    return trace == null || trace.spun;
  }

  /// Whether [fanReadings] has anything to show — the panel hides the whole
  /// section otherwise.
  bool get hasFanRows {
    for (var i = 0; i < fans.length; i++) {
      if (_fanRowVisible(i)) return true;
    }
    return false;
  }

  /// Folds one sample into a fan's row bookkeeping. Null is "this poll read
  /// nothing" and leaves the trace alone; zero is a real reading — a fan that
  /// has turned and now reads zero is a stopped fan, not a missing row.
  void _traceFan(int i, double? rpm) {
    final trace = _fanTrace.putIfAbsent(i, () => _FanTrace());
    if (rpm == null) return;
    trace.lastRpm = rpm;
    if (rpm > 0) trace.spun = true;
  }

  /// Test seam: folds hand-fed per-fan samples through the same bookkeeping
  /// the poll uses, so the row rules behind [fanReadings] can be driven
  /// without a backend.
  @visibleForTesting
  void sampleFans(List<double?> rpms) {
    for (var i = 0; i < fans.length; i++) {
      _traceFan(i, i < rpms.length ? rpms[i] : null);
    }
    notifyListeners();
  }

  static final _numberedFan = RegExp(r'^fan #?(\d+)$', caseSensitive: false);

  static String _fanLabel(FanRef fan) {
    final name = fan.sensorName.trim();
    final lower = name.toLowerCase();
    if (name.isEmpty || lower == 'fan') return '风扇';
    // Board headers number their fans in English whatever the rest of the
    // panel speaks; the number is the header's, so it stays.
    final numbered = _numberedFan.firstMatch(lower);
    if (numbered != null) return '风扇 ${numbered.group(1)}';
    return name;
  }

  double? diskActivity(int index) =>
      index < disks.length ? _doubleValue(disks[index].activity) : null;

  double? diskReadKbps(int index) =>
      index < disks.length ? _doubleValue(disks[index].readRate) : null;

  double? diskWriteKbps(int index) =>
      index < disks.length ? _doubleValue(disks[index].writeRate) : null;

  double? diskTemp(int index) =>
      index < disks.length ? _doubleValue(disks[index].temperature) : null;

  /// First network adapter that is currently up (fallback: first adapter).
  NetRef? get activeNet {
    for (final n in nets) {
      final up = _doubleValue(n.linkUp);
      if (up != null && up > 0) return n;
    }
    return nets.isNotEmpty ? nets.first : null;
  }

  double? get downloadKbps {
    final net = activeNet;
    return net == null ? null : _doubleValue(net.rxRate);
  }

  double? get uploadKbps {
    final net = activeNet;
    return net == null ? null : _doubleValue(net.txRate);
  }

  // ---- battery (null battery = desktop without one) ----

  bool get hasBattery => battery != null;

  double? get batteryChargePct => _doubleValue(battery?.chargePct);

  /// Signed watts, normalized to positive = charging / negative = discharging
  /// (the DLL forwards batclass BATTERY_STATUS.Rate, which is the reverse).
  double? get batteryRateW {
    final v = _doubleValue(battery?.rateMw);
    return v == null ? null : -v / 1000.0;
  }

  /// The DLL reports English state strings ("Charging", "AC Power", …);
  /// translate for display. Null when the reading is not (yet) available.
  String? get batteryStateText {
    final v = rawValue(battery?.state);
    if (v == null || v.status != statusOk) return null;
    final s = v.asString;
    if (s.isEmpty) return null;
    final critical = s.contains('Critical');
    final base = s.startsWith('Charging')
        ? '充电中'
        : s.startsWith('Discharging')
            ? '放电中'
            : s.startsWith('AC Power (Fully')
                ? '已充满'
                : s.startsWith('AC Power')
                    ? '外接电源'
                    : s.startsWith('Idle')
                        ? '空闲'
                        : s;
    return critical ? '$base · 电量危急' : base;
  }

  /// True when the kernel driver is not installed (temps/fans are gated).
  bool get driverMissing {
    if (status != HwprobeStatus.ready) return false;
    final cpuTempValue = rawValue(_cpuTemp);
    if (cpuTempValue != null && cpuTempValue.status == statusNoDriver) {
      return true;
    }
    // Without any CPU temperature sensor the driver is definitely absent.
    return _cpuTemp == null;
  }

  /// Set after the driver installer finished successfully; the sensor tree
  /// only picks up the new driver after the app restarts.
  bool driverInstallPendingRestart = false;

  /// PawnIO opens its device only for elevated processes; the driver may be
  /// installed and running while temps still stay gated for non-admin runs.
  ///
  /// The answer costs an SCM round trip, and the panel asks once per second, so
  /// it is memoized for a few seconds. Reinstalling changes it at the next
  /// refresh — and [installDriver] forces one immediately.
  static const _serviceCheckEvery = Duration(seconds: 10);
  bool? _driverServiceCache;
  DateTime? _driverServiceAt;

  bool get driverServiceRunning {
    final cached = _driverServiceCache;
    final at = _driverServiceAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _serviceCheckEvery) {
      return cached;
    }
    return _refreshDriverService();
  }

  bool _refreshDriverService() {
    final running = isServiceRunning('PawnIO');
    _driverServiceCache = running;
    _driverServiceAt = DateTime.now();
    return running;
  }

  /// Installs the PawnIO kernel driver (UAC prompt). Takes effect after the
  /// app restarts. Returns the native status code.
  Future<int> installDriver() async {
    final path = _dllPath;
    final rc = await Isolate.run(() {
      final b = HwprobeBindings.load(explicitPath: path);
      return b.setupDriver();
    });
    if (rc == statusOk) {
      driverInstallPendingRestart = true;
      // The service just changed state; do not serve the cached answer.
      _driverServiceCache = null;
      _driverServiceAt = null;
      notifyListeners();
    }
    return rc;
  }

  /// Switches the utilization sampling mode — [usageModeStandard] or
  /// [usageModeTaskManager]. Documented safe before init or mid-run: the DLL
  /// applies it on its next refresh, so readings follow within a second.
  /// The mode is remembered even when the backend is down, and HomeScreen
  /// re-applies the persisted value after start().
  void setUsageMode(int mode) {
    if (mode == usageMode) return;
    usageMode = mode;
    _bindings?.setUsageMode(mode);
  }

  /// Exits and relaunches the app elevated (UAC). Returns false when the
  /// elevation prompt was declined or failed.
  Future<bool> restartAsAdmin() async {
    await shutdown();
    final exe = Platform.resolvedExecutable;
    final ok = shellExecuteRunAs(exe);
    if (ok) exit(0);
    return false;
  }

  Future<void> shutdown() async {
    _shuttingDown = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _freeReadingBuffer();
    _bindings?.shutdown();
  }

  @override
  void dispose() {
    _shuttingDown = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    final listener = _activityListener;
    if (listener != null) AppActivity.visible.removeListener(listener);
    _activityListener = null;
    _freeReadingBuffer();
    super.dispose();
  }
}
