// Dev-only probe: validates the production icon extraction path and writes
// sample PNGs named after each target.
// Run: dart run tool/icon_probe.dart "path\to\file.lnk" ...
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:xgame_desktop/native/icon_extract.dart';

void main(List<String> args) {
  final targets = args.isNotEmpty
      ? args
      : [
          r'C:\Users\89574\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\ZCode.lnk',
          r'C:\Windows\System32\notepad.exe',
        ];
  for (final t in targets) {
    final png =
        extractIconToCache(t, Directory.systemTemp.path, kIconRequestSize);
    stdout.writeln('$t -> ${png ?? '<failed>'}');
    if (png == null) continue;
    final f = File(png);
    final out = '${_safeName(t)}.png';
    f.copySync(out);
    stdout.writeln('  ${f.lengthSync()} bytes -> $out');
  }
}

String _safeName(String path) {
  final base = path.replaceAll('/', '\\').split('\\').last;
  return base.replaceAll(RegExp(r'[^A-Za-z0-9_.\u4e00-\u9fff-]'), '_');
}
