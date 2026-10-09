// Dev probe: drives the native open-file dialog and prints what came back.
// Run it, then cancel (Esc) or type a path and press Enter.
//
//   dart run tool/dialog_probe.dart
//
// A cancel prints `cancelled, cderr=0` — that is the healthy result. Any
// other cderr code means the OPENFILENAMEW layout was rejected.
// ignore_for_file: avoid_print

import 'package:xgame_desktop/native/win32_api.dart';

void main() {
  final watch = Stopwatch()..start();
  final path = pickImageFile();
  watch.stop();
  print('elapsed=${watch.elapsedMilliseconds}ms '
      'cderr=0x${lastFileDialogError.toRadixString(16)} '
      'result=${path ?? '(none)'}');
}
