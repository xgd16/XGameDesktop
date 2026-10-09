// Dev-only: which cached icons carry the shell's hairline canvas outline?
//
// Windows' shell image pipeline sometimes answers a large icon request with a
// "hollow" frame: the logo plus a 1px line around the whole canvas. On the
// launcher's dark grid that line reads as a box around the icon — which the
// extractor guards against by comparing ink (_loadBestPixels), but a cache
// file written before the guard, or by a frame the guard let through, keeps
// being served.
//
//   dart run tool/icon_outline_scan.dart
//
// For every scanned app it prints: the outline fraction of the cached PNG
// (share of border pixels carrying any ink), and what a fresh extraction
// picks today (px size + that frame's outline fraction).
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:xgame_desktop/native/icon_extract.dart';
import 'package:xgame_desktop/native/shell_apps.dart';

void main() {
  final cacheDir = Directory(
      '${Platform.environment['LOCALAPPDATA']}\\XGameDesktop\\icons');
  final freshDir = Directory.systemTemp.createTempSync('icon_outline').path;
  var cached = 0, boxed = 0, boxedAfterFresh = 0;
  final rows = <String>[];
  for (final app in ShellApps.scan()) {
    final key = _cacheName(app.path, kIconRequestSize);
    final file = File('${cacheDir.path}\\$key.png');
    if (!file.existsSync()) continue;
    cached++;
    final old = _outline(file);
    final freshPath = extractIconToCache(app.path, freshDir, kIconRequestSize);
    final freshImage =
        freshPath == null ? null : img.decodePng(File(freshPath).readAsBytesSync())!;
    final fresh = freshPath == null
        ? 'failed'
        : '${freshImage!.width}px ${_outline(File(freshPath)).toStringAsFixed(3)}';
    if (old >= 0.9) boxed++;
    if (freshImage != null && _outline(File(freshPath!)) >= 0.9) {
      boxedAfterFresh++;
    }
    rows.add('${old.toStringAsFixed(3).padLeft(5)}  '
        'cached=${img.decodePng(file.readAsBytesSync())!.width}px  '
        'fresh[$fresh]  ${app.name}  <${app.path}>');
  }
  rows.sort((a, b) => b.compareTo(a));
  print('cached=$cached  boxed(outline>=0.9)=$boxed  '
      'boxedAfterFresh=$boxedAfterFresh');
  for (final row in rows) {
    print(row);
  }
}

/// Share of the canvas border pixels (top/bottom rows, left/right columns)
/// that carry any ink. A hairline canvas outline scores ~1.0; a logo that
/// happens to touch an edge scores well below it, since a square canvas has
/// four corners and a drawn icon rarely inks all of them.
double _outline(File png) {
  final im = img.decodePng(png.readAsBytesSync())!;
  var inked = 0, total = 0;
  void check(int x, int y) {
    total++;
    if (im.getPixel(x, y).a.toInt() != 0) inked++;
  }

  for (var x = 0; x < im.width; x++) {
    check(x, 0);
    check(x, im.height - 1);
  }
  for (var y = 1; y < im.height - 1; y++) {
    check(0, y);
    check(im.width - 1, y);
  }
  return inked / total;
}

/// Mirrors icon_extract's cache key: `v<version>|<lowercased path>|<size>`,
/// FNV-1a 64 over its UTF-8 bytes. The version is private over there — keep
/// this in step when it is bumped.
const int _cacheVersion = 6;

int _cacheName(String sourcePath, int size) {
  var hash = 0xcbf29ce484222325;
  final key = 'v$_cacheVersion|${sourcePath.toLowerCase()}|$size';
  for (final code in utf8.encode(key)) {
    hash ^= code;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash;
}
