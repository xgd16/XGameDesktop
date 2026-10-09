// Dev-only smoke test: loads hwprobe.dll directly, verifies struct layout
// against hwprobe_dump_json output, and prints every sensor code found.
// Run: dart run tool/dump_sensors.dart
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:xgame_desktop/native/hwprobe_bindings.dart';
void main(List<String> args) {
  final path = args.isNotEmpty
      ? args[0]
      : r'E:\code\hwprobe\bin\dll\hwprobe.dll';
  final bindings = HwprobeBindings.load(explicitPath: path);

  final abi = bindings.abiVersion;
  stdout.writeln('abi_version = $abi (expect $hwprobeAbiVersion)');
  if (abi != hwprobeAbiVersion) {
    stderr.writeln('ABI mismatch, aborting');
    exit(2);
  }

  final rcInit = bindings.init();
  stdout.writeln('init rc = $rcInit');
  if (rcInit != statusOk && rcInit != statusWaiting) {
    stderr.writeln('last_error = ${lastErrorText(bindings)}');
    exit(3);
  }

  // Give the background poller a moment on first init.
  if (rcInit == statusWaiting) {
    stdout.writeln('waiting for first refresh...');
    for (var i = 0; i < 30; i++) {
      sleep(const Duration(milliseconds: 200));
      if (bindings.readSensor(0, 0, 0, calloc<HwprobeReading>()) !=
          statusNotInitialized) {
        break;
      }
    }
  }

  // ---- struct enumeration path ----
  final catCount = calloc<Uint32>();
  bindings.getCategoryCount(catCount);
  stdout.writeln('\nstruct path: ${catCount.value} categories');
  for (var c = 0; c < catCount.value; c++) {
    final cat = calloc<HwprobeCategoryInfo>();
    cat.ref.size = sizeOf<HwprobeCategoryInfo>();
    final rc = bindings.getCategoryInfo(c, cat);
    if (rc != statusOk) continue;
    stdout.writeln('[$c] ${cat.ref.nameText} devices=${cat.ref.deviceCount}');
    for (var d = 0; d < cat.ref.deviceCount; d++) {
      final dev = calloc<HwprobeDeviceInfo>();
      dev.ref.size = sizeOf<HwprobeDeviceInfo>();
      if (bindings.getDeviceInfo(c, d, dev) != statusOk) continue;
      stdout.writeln(
          '  device[$d]: ${dev.ref.nameText}  (vendor=${dev.ref.vendorText})');
      final senCount = calloc<Uint32>();
      bindings.getSensorCount(c, d, senCount);
      for (var s = 0; s < senCount.value; s++) {
        final sen = calloc<HwprobeSensorInfo>();
        sen.ref.size = sizeOf<HwprobeSensorInfo>();
        if (bindings.getSensorInfo(c, d, s, sen) != statusOk) continue;
        final info = sen.ref;
        final reading = calloc<HwprobeReading>();
        reading.ref.size = sizeOf<HwprobeReading>();
        final rrc = bindings.readSensor(c, d, s, reading);
        String valueText;
        if (rrc == statusOk) {
          final rd = reading.ref;
          valueText = rd.valueType == vtypeString
              ? '"${rd.value.sText}"'
              : rd.doubleValue.toStringAsFixed(2);
          if (rd.status != statusOk) valueText += ' [status=${rd.status}]';
        } else {
          valueText = '<rc=$rrc>';
        }
        stdout.writeln(
            '    sensor[$s] code="${info.codeText}" name="${info.nameText}" '
            'unit="${info.unitText}" kind=${info.kind} vt=${info.valueType} '
            '-> $valueText');
        calloc.free(sen);
        calloc.free(reading);
      }
      calloc.free(senCount);
      calloc.free(dev);
    }
    calloc.free(cat);
  }
  calloc.free(catCount);

  // ---- dump_json path (cross-check) ----
  final len = calloc<Uint32>();
  bindings.dumpJson(catAll, nullptr, len);
  final buf = calloc<Uint8>(len.value);
  final rcJson = bindings.dumpJson(catAll, buf, len);
  if (rcJson == statusOk) {
    final json = const Utf8Decoder()
        .convert(buf.asTypedList(len.value - 1 > 0 ? len.value - 1 : len.value));
    final tree = jsonDecode(json) as Map<String, dynamic>;
    final cats = tree['categories'] as List<dynamic>? ?? const [];
    stdout.writeln('\ndump_json path: ${cats.length} categories, '
        'json bytes=${len.value}');
  } else {
    stdout.writeln('\ndump_json rc=$rcJson');
  }
  calloc.free(buf);
  calloc.free(len);

  bindings.shutdown();
  stdout.writeln('\nshutdown ok');
}

String lastErrorText(HwprobeBindings bindings) {
  final len = calloc<Uint32>();
  bindings.lastError(nullptr, len);
  if (len.value <= 1) {
    calloc.free(len);
    return '';
  }
  final buf = calloc<Uint8>(len.value);
  bindings.lastError(buf, len);
  final text = const Utf8Decoder().convert(buf.asTypedList(len.value - 1));
  calloc.free(buf);
  calloc.free(len);
  return text;
}
