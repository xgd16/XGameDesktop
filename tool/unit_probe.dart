// ignore_for_file: avoid_print
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:xgame_desktop/native/hwprobe_bindings.dart';

void main(List<String> args) {
  final path = args.first;
  final b = HwprobeBindings.load(explicitPath: path);
  b.init();
  sleep(const Duration(milliseconds: 1500));
  final senCount = calloc<Uint32>();
  b.getSensorCount(catCpu, 0, senCount);
  print('$path -> cpu sensors=${senCount.value} '
      '${senCount.value > 32 ? "TEMPS OK" : "no temps"}');
  calloc.free(senCount);
  b.shutdown();
}
