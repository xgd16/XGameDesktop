// ignore_for_file: avoid_print
// Dev-only: which frame size does the extractor pick for every app on this
// machine, and how much ink does each choice carry?
//   dart run tool/icon_choice_probe.dart
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:xgame_desktop/native/icon_extract.dart';
import 'package:xgame_desktop/native/shell_apps.dart';

void main() {
  final dir = Directory.systemTemp.createTempSync('icon_choice').path;
  final apps = ShellApps.scan();
  final counts = <int, int>{};
  final fallbacks = <String>[];
  final failures = <String>[];
  for (final app in apps) {
    final png = extractIconToCache(app.path, dir, kIconRequestSize);
    if (png == null) {
      failures.add(app.name);
      counts[0] = (counts[0] ?? 0) + 1;
      continue;
    }
    final image = img.decodePng(File(png).readAsBytesSync())!;
    counts[image.width] = (counts[image.width] ?? 0) + 1;
    if (image.width < kIconRequestSize) fallbacks.add(app.name);
  }
  print('total=${apps.length}');
  for (final entry in counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value))) {
    print('  ${entry.key}px: ${entry.value}');
  }
  print('\nfallbacks (large frame rejected as hollow):');
  for (final name in fallbacks) {
    print('  $name');
  }
  print('\nfailures:');
  for (final name in failures) {
    print('  $name');
  }
  Directory(dir).deleteSync(recursive: true);
}
