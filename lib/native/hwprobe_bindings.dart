import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

// Bindings for E:\code\hwprobe\bin\dll\hwprobe.h (ABI version 4).
// All structs are caller-allocated; the DLL backfills the leading `size`
// field. Strings are fixed char[N] UTF-8 arrays, NUL-terminated.

const int hwprobeAbiVersion = 4;

const int catCpu = 0;
const int catMemory = 1;
const int catGpu = 2;
const int catDisk = 3;
const int catNetwork = 4;
const int catBattery = 5;
const int catMotherboard = 6;
const int catDisplay = 7;
const int catImu = 8;
const int catAll = 0xFFFFFFFF;

const int statusOk = 0;
const int statusWaiting = 1;
const int statusNotInitialized = 2;
const int statusInitFailed = 3;
const int statusInvalidArg = 4;
const int statusBadCategory = 5;
const int statusBadDevice = 6;
const int statusBadSensor = 7;
const int statusNoDriver = 8;
const int statusNotSupported = 9;
const int statusError = 10;
const int statusBufferTooSmall = 11;
const int statusUnknown = 12;
const int statusBadHandle = 13;

// hwprobe_value_type
const int vtypeF64 = 0;
const int vtypeU64 = 1;
const int vtypeI64 = 2;
const int vtypeBool = 3;
const int vtypeString = 4;

// hwprobe_sensor kind
const int sensorKindStatic = 0;
const int sensorKindDynamic = 1;

// hwprobe usage mode (hwprobe_set_usage_mode). Both modes only change where
// the utilization-type sensors (CPU total/per-core, GPU total) read from.
const int usageModeStandard = 0;
const int usageModeTaskManager = 1;

final class HwprobeCategoryInfo extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int index;
  @Array(32)
  external Array<Uint8> name;
  @Uint32()
  external int deviceCount;

  String get nameText => decodeFixedString(name, 32);
}

final class HwprobeDeviceInfo extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int category;
  @Uint32()
  external int index;
  @Array(128)
  external Array<Uint8> id;
  @Array(192)
  external Array<Uint8> name;
  @Array(96)
  external Array<Uint8> vendor;
  @Array(96)
  external Array<Uint8> model;
  @Array(96)
  external Array<Uint8> serial;

  String get idText => decodeFixedString(id, 128);
  String get nameText => decodeFixedString(name, 192);
  String get vendorText => decodeFixedString(vendor, 96);
  String get modelText => decodeFixedString(model, 96);
}

final class HwprobeSensorInfo extends Struct {
  @Uint32()
  external int size;
  @Array(64)
  external Array<Uint8> code;
  @Array(96)
  external Array<Uint8> name;
  @Array(16)
  external Array<Uint8> unit;
  @Uint32()
  external int kind;
  @Uint32()
  external int valueType;

  String get codeText => decodeFixedString(code, 64);
  String get nameText => decodeFixedString(name, 96);
  String get unitText => decodeFixedString(unit, 16);
}

final class HwprobeValue extends Union {
  @Double()
  external double f64;
  @Uint64()
  external int u64;
  @Int64()
  external int i64;
  @Uint8()
  external int b;
  @Array(96)
  external Array<Uint8> s;

  String get sText => decodeFixedString(s, 96);
}

final class HwprobeReading extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int valueType;
  @Uint32()
  external int status;
  @Uint64()
  external int timestampMs;
  external HwprobeValue value;

  double get doubleValue => switch (valueType) {
        vtypeF64 => value.f64,
        vtypeU64 => value.u64.toDouble(),
        vtypeI64 => value.i64.toDouble(),
        vtypeBool => value.b.toDouble(),
        _ => 0,
      };

  String get stringValue => switch (valueType) {
        vtypeString => value.sText,
        vtypeBool => value.b == 0 ? 'false' : 'true',
        _ => '',
      };
}

final class HwprobeStreamItem extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int category;
  @Uint32()
  external int device;
  @Uint32()
  external int sensor;
  @Uint32()
  external int valueType;
  @Uint32()
  external int status;
  @Uint64()
  external int timestampMs;
  external HwprobeValue value;
}

final class HwprobeStreamBatch extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int count;
  @Uint64()
  external int seq;
  @Uint64()
  external int timestampMs;
  external Pointer<HwprobeStreamItem> items;
}

/// Scratch for [decodeFixedString]. Names are decoded once per enumeration and
/// the battery-state string once a second; a fixed buffer keeps that free of
/// per-call growable-list churn, and a Uint8List is what utf8.decode's fast
/// path takes.
final Uint8List _stringScratch = Uint8List(128);

String decodeFixedString(Array<Uint8> array, int maxLen) {
  final bytes =
      maxLen <= _stringScratch.length ? _stringScratch : Uint8List(maxLen);
  var end = 0;
  for (; end < maxLen; end++) {
    final b = array[end];
    if (b == 0) break;
    bytes[end] = b;
  }
  return utf8.decode(Uint8List.sublistView(bytes, 0, end), allowMalformed: true);
}

double decodeValueDouble(int valueType, HwprobeValue value) {
  switch (valueType) {
    case vtypeF64:
      return value.f64;
    case vtypeU64:
      return value.u64.toDouble();
    case vtypeI64:
      return value.i64.toDouble();
    case vtypeBool:
      return value.b.toDouble();
    default:
      return 0;
  }
}

String decodeValueString(int valueType, HwprobeValue value) {
  if (valueType == vtypeString) return value.sText;
  if (valueType == vtypeBool) return value.b == 0 ? 'false' : 'true';
  return '';
}

// ---- function typedefs ----

typedef _AbiVersionC = Uint32 Function();
typedef AbiVersionDart = int Function();

typedef _InitC = Int32 Function();
typedef InitDart = int Function();

typedef _ShutdownC = Int32 Function();
typedef ShutdownDart = int Function();

typedef _SetPollIntervalC = Int32 Function(Uint32 ms);
typedef SetPollIntervalDart = int Function(int ms);

typedef _GetCategoryCountC = Int32 Function(Pointer<Uint32>);
typedef GetCategoryCountDart = int Function(Pointer<Uint32>);

typedef _GetCategoryInfoC = Int32 Function(
    Uint32 category, Pointer<HwprobeCategoryInfo>);
typedef GetCategoryInfoDart = int Function(
    int category, Pointer<HwprobeCategoryInfo>);

typedef _GetDeviceCountC = Int32 Function(Uint32 category, Pointer<Uint32>);
typedef GetDeviceCountDart = int Function(int category, Pointer<Uint32>);

typedef _GetDeviceInfoC = Int32 Function(
    Uint32 category, Uint32 device, Pointer<HwprobeDeviceInfo>);
typedef GetDeviceInfoDart = int Function(
    int category, int device, Pointer<HwprobeDeviceInfo>);

typedef _GetSensorCountC = Int32 Function(
    Uint32 category, Uint32 device, Pointer<Uint32>);
typedef GetSensorCountDart = int Function(
    int category, int device, Pointer<Uint32>);

typedef _GetSensorInfoC = Int32 Function(Uint32 category, Uint32 device,
    Uint32 sensor, Pointer<HwprobeSensorInfo>);
typedef GetSensorInfoDart = int Function(
    int category, int device, int sensor, Pointer<HwprobeSensorInfo>);

typedef _RefreshC = Int32 Function(Uint32 category);
typedef RefreshDart = int Function(int category);

typedef _ReadSensorC = Int32 Function(Uint32 category, Uint32 device,
    Uint32 sensor, Pointer<HwprobeReading>);
typedef ReadSensorDart = int Function(
    int category, int device, int sensor, Pointer<HwprobeReading>);

typedef _DumpJsonC = Int32 Function(
    Uint32 category, Pointer<Uint8>, Pointer<Uint32>);
typedef DumpJsonDart = int Function(
    int category, Pointer<Uint8>, Pointer<Uint32>);

typedef _LastErrorC = Int32 Function(Pointer<Uint8>, Pointer<Uint32>);
typedef LastErrorDart = int Function(Pointer<Uint8>, Pointer<Uint32>);

typedef StreamCallbackC = Void Function(
    Pointer<HwprobeStreamBatch> batch, Pointer<Void> userData);
typedef StreamCallbackDart = void Function(
    Pointer<HwprobeStreamBatch> batch, Pointer<Void> userData);

typedef _SubscribeC = Int32 Function(Pointer<NativeFunction<StreamCallbackC>>,
    Pointer<Void>, Uint32 intervalMs, Uint32 categoryMask, Pointer<Uint64>);
typedef SubscribeDart = int Function(Pointer<NativeFunction<StreamCallbackC>>,
    Pointer<Void>, int intervalMs, int categoryMask, Pointer<Uint64>);

typedef _UnsubscribeC = Int32 Function(Uint64 handle);
typedef UnsubscribeDart = int Function(int handle);

typedef _SetupDriverC = Int32 Function();
typedef SetupDriverDart = int Function();

typedef _SetUsageModeC = Int32 Function(Uint32 mode);
typedef SetUsageModeDart = int Function(int mode);

class HwprobeBindings {
  HwprobeBindings._(this._lib) {
    _abiVersion = _lib
        .lookupFunction<_AbiVersionC, AbiVersionDart>('hwprobe_abi_version');
    init = _lib.lookupFunction<_InitC, InitDart>('hwprobe_init');
    shutdown =
        _lib.lookupFunction<_ShutdownC, ShutdownDart>('hwprobe_shutdown');
    setPollInterval = _lib
        .lookupFunction<_SetPollIntervalC, SetPollIntervalDart>(
            'hwprobe_set_poll_interval');
    getCategoryCount = _lib
        .lookupFunction<_GetCategoryCountC, GetCategoryCountDart>(
            'hwprobe_get_category_count');
    getCategoryInfo = _lib
        .lookupFunction<_GetCategoryInfoC, GetCategoryInfoDart>(
            'hwprobe_get_category_info');
    getDeviceCount = _lib
        .lookupFunction<_GetDeviceCountC, GetDeviceCountDart>(
            'hwprobe_get_device_count');
    getDeviceInfo = _lib
        .lookupFunction<_GetDeviceInfoC, GetDeviceInfoDart>(
            'hwprobe_get_device_info');
    getSensorCount = _lib
        .lookupFunction<_GetSensorCountC, GetSensorCountDart>(
            'hwprobe_get_sensor_count');
    getSensorInfo = _lib
        .lookupFunction<_GetSensorInfoC, GetSensorInfoDart>(
            'hwprobe_get_sensor_info');
    refresh =
        _lib.lookupFunction<_RefreshC, RefreshDart>('hwprobe_refresh');
    readSensor = _lib
        .lookupFunction<_ReadSensorC, ReadSensorDart>('hwprobe_read_sensor');
    dumpJson =
        _lib.lookupFunction<_DumpJsonC, DumpJsonDart>('hwprobe_dump_json');
    lastError = _lib
        .lookupFunction<_LastErrorC, LastErrorDart>('hwprobe_last_error');
    subscribe = _lib
        .lookupFunction<_SubscribeC, SubscribeDart>('hwprobe_subscribe');
    unsubscribe = _lib
        .lookupFunction<_UnsubscribeC, UnsubscribeDart>('hwprobe_unsubscribe');
    setupDriver = _lib
        .lookupFunction<_SetupDriverC, SetupDriverDart>('hwprobe_setup_driver');
    setUsageMode = _lib
        .lookupFunction<_SetUsageModeC, SetUsageModeDart>(
            'hwprobe_set_usage_mode');
  }

  static HwprobeBindings? _instance;

  /// Loads hwprobe.dll. [explicitPath] bypasses the default search order.
  static HwprobeBindings load({String? explicitPath}) {
    if (_instance != null) return _instance!;
    final lib = _openLibrary(explicitPath);
    _instance = HwprobeBindings._(lib);
    return _instance!;
  }

  static DynamicLibrary _openLibrary(String? explicitPath) {
    if (explicitPath != null) return DynamicLibrary.open(explicitPath);
    try {
      return DynamicLibrary.open('hwprobe.dll');
    } catch (_) {
      // Fallback: next to the running exe.
      final exe = Platform.resolvedExecutable;
      final dir = exe.substring(0, exe.lastIndexOf('\\'));
      return DynamicLibrary.open('$dir\\hwprobe.dll');
    }
  }

  final DynamicLibrary _lib;

  late final AbiVersionDart _abiVersion;
  late final InitDart init;
  late final ShutdownDart shutdown;
  late final SetPollIntervalDart setPollInterval;
  late final GetCategoryCountDart getCategoryCount;
  late final GetCategoryInfoDart getCategoryInfo;
  late final GetDeviceCountDart getDeviceCount;
  late final GetDeviceInfoDart getDeviceInfo;
  late final GetSensorCountDart getSensorCount;
  late final GetSensorInfoDart getSensorInfo;
  late final RefreshDart refresh;
  late final ReadSensorDart readSensor;
  late final DumpJsonDart dumpJson;
  late final LastErrorDart lastError;
  late final SubscribeDart subscribe;
  late final UnsubscribeDart unsubscribe;
  late final SetupDriverDart setupDriver;
  late final SetUsageModeDart setUsageMode;

  int get abiVersion => _abiVersion();
}

/// Copies [count] stream items out of a batch pointer. Must be called during
/// the callback invocation — the native memory is not valid afterwards.
List<(int, int, int, int, HwprobeReadingValue)> copyStreamBatch(
    Pointer<HwprobeStreamBatch> batch) {
  final b = batch.ref;
  final result = <(int, int, int, int, HwprobeReadingValue)>[];
  for (var i = 0; i < b.count; i++) {
    final item = b.items[i];
    result.add((
      item.category,
      item.device,
      item.sensor,
      item.valueType,
      HwprobeReadingValue(
        status: item.status,
        timestampMs: item.timestampMs,
        valueType: item.valueType,
        f64: item.value.f64,
        u64: item.value.u64,
        i64: item.value.i64,
        b: item.value.b,
        s: item.value.sText,
      ),
    ));
  }
  return result;
}

/// A plain-Dart snapshot of a sensor value, safe to hold across frames.
class HwprobeReadingValue {
  HwprobeReadingValue({
    required this.status,
    required this.timestampMs,
    required this.valueType,
    required this.f64,
    required this.u64,
    required this.i64,
    required this.b,
    required this.s,
  });

  final int status;
  final int timestampMs;
  final int valueType;
  final double f64;
  final int u64;
  final int i64;
  final int b;
  final String s;

  double get asDouble => switch (valueType) {
        vtypeF64 => f64,
        vtypeU64 => u64.toDouble(),
        vtypeI64 => i64.toDouble(),
        vtypeBool => b.toDouble(),
        _ => 0,
      };

  String get asString => switch (valueType) {
        vtypeString => s,
        vtypeBool => b == 0 ? 'false' : 'true',
        _ => '',
      };
}
