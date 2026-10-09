// Asks the same question GamepadService asks each poll: would the app answer
// the pad right now? Takes the app's top-level HWND and prints the verdict.
//
// The pad is a global poll — XInput reads whichever pad is plugged in whoever
// is in front — so this check is the only thing standing between "the app
// reacts to the pad" and "the app reacts to the pad the user is aiming at the
// game in front". Run it with the app focused and with another window in
// front; the boolean has to flip.
//
//   dart run tool/foreground_probe.dart <hwnd>
//
// The HWND is the app's top-level window, e.g. from PowerShell:
//   (Get-Process xgame_desktop).MainWindowHandle
import 'dart:io';

import 'package:xgame_desktop/native/win32_api.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/foreground_probe.dart <hwnd>');
    exit(2);
  }
  final hwnd = int.tryParse(args.single);
  if (hwnd == null) {
    stderr.writeln('not a window handle: ${args.single}');
    exit(2);
  }
  stdout.writeln('hwnd=$hwnd appIsForeground=${appIsForeground(hwnd)}');
}
