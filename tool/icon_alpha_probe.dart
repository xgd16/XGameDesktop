// Dev-only: draws an icon's alpha channel as a character map, to see what a
// tile will actually look like behind the launcher's dark grid — in
// particular whether the frame the shell hands back carries a faint outline
// (the "hollow large frame" artifact _loadBestPixels guards against).
//
//   dart run tool/icon_alpha_probe.dart "<path to .lnk / .exe>" [size]
//
// Prints the map for the requested size and for 48 px, plus how many pixels
// are clear / faint / solid in each.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:xgame_desktop/native/icon_extract.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/icon_alpha_probe.dart <path> [size]');
    exit(2);
  }
  final path = args[0];
  // A PNG is analysed as-is: the cache files are the ones the grid draws, and
  // a stale one is exactly what a "why is there a box" question is about.
  if (path.toLowerCase().endsWith('.png')) {
    final im = img.decodePng(File(path).readAsBytesSync())!;
    print('=== $path -> ${im.width}x${im.height}');
    _printMap(im);
    _printCounts(im);
    return;
  }
  final size = args.length > 1 ? int.parse(args[1]) : kIconRequestSize;
  final dir = Directory.systemTemp.createTempSync('icon_alpha').path;

  for (final request in {size, 48}) {
    final png = extractIconToCache(path, dir, request);
    if (png == null) {
      print('=== requested $request -> extraction failed');
      continue;
    }
    final im = img.decodePng(File(png).readAsBytesSync())!;
    print('=== requested $request -> ${im.width}x${im.height}');
    _printMap(im);
    _printCounts(im);
  }
}

void _printCounts(img.Image im) {
  var clear = 0, faint = 0, solid = 0;
  for (final p in im) {
    final a = p.a.toInt();
    if (a == 0) {
      clear++;
    } else if (a <= 80) {
      faint++;
    } else {
      solid++;
    }
  }
  print('alpha: clear=$clear faint(1-80)=$faint solid(>80)=$solid');
}

void _printMap(img.Image im) {
  // Space = clear, . = very faint (1..80), - = faint (81..200), # = solid.
  const cols = 48;
  final step = im.width / cols;
  for (var row = 0; row < cols; row++) {
    final line = StringBuffer('|');
    for (var col = 0; col < cols; col++) {
      final x = (col * step).floor().clamp(0, im.width - 1);
      final y = (row * step).floor().clamp(0, im.height - 1);
      final a = im.getPixel(x, y).a.toInt();
      line.write(a == 0 ? ' ' : (a <= 80 ? '.' : (a <= 200 ? '-' : '#')));
    }
    line.write('|');
    print(line);
  }
}
