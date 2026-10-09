// Probe: what does IShellItemImageFactory hand back for a Wallpaper Engine
// file? Prints the returned bitmap size and how uniform its outer bands are
// (letterbox bars show up as near-black edges), and optionally dumps a PNG.
//
//   dart run tool/thumb_probe.dart <path> [cx] [cy] [flags] [out.png]
//
// flags defaults to THUMBNAILONLY|BIGGERSIZEOK (9).
// ignore_for_file: avoid_print, avoid_relative_lib_imports
import 'dart:io';

import '../lib/native/bgra_png.dart';
import '../lib/native/win32_api.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: thumb_probe <path> [cx] [cy] [flags] [out.png]');
    exit(2);
  }
  final path = args[0];
  final cx = args.length > 1 ? int.parse(args[1]) : 1920;
  final cy = args.length > 2 ? int.parse(args[2]) : 1080;
  final flags = args.length > 3
      ? int.parse(args[3])
      : siigbfThumbnailOnly | siigbfBiggerSizeOk;
  final out = args.length > 4 ? args[4] : null;

  coInitialize();
  final t0 = DateTime.now();
  final hbmp = shellItemImageHandle(path, cx, cy: cy, flags: flags);
  final ms = DateTime.now().difference(t0).inMilliseconds;
  if (hbmp == 0) {
    print('handle=0 (no image) box=${cx}x$cy flags=$flags in ${ms}ms');
    exit(1);
  }
  try {
    final px = hBitmapToPixels(hbmp);
    if (px == null) {
      print('hBitmapToPixels=null in ${ms}ms');
      exit(1);
    }
    print('box=${cx}x$cy flags=$flags -> got ${px.width}x${px.height} '
        '(${ms}ms) ink=${_ink(px).toStringAsFixed(3)}');
    print('edges: top=${_band(px, 0)} bottom=${_band(px, px.height - 1)} '
        'left=${_colBand(px, 0)} right=${_colBand(px, px.width - 1)}');
    if (out != null) {
      final png = encodeBgraPng(px);
      if (png == null) {
        print('encode failed');
      } else {
        File(out).writeAsBytesSync(png);
        print('wrote $out (${png.length} bytes)');
      }
    }
  } finally {
    deleteGdiObject(hbmp);
  }
}

double _ink(IconPixels px) {
  var ink = 0;
  for (final p in px.bgra) {
    if (((p >> 24) & 0xFF) > 8 || (p & 0xFFFFFF) != 0) ink++;
  }
  return ink / (px.width * px.height);
}

/// Mean luminance of row [y] — a letterbox bar reads ~0.
double _band(IconPixels px, int y) {
  var sum = 0.0;
  for (var x = 0; x < px.width; x++) {
    final p = px.bgra[y * px.width + x];
    sum += ((p >> 16) & 0xFF) + ((p >> 8) & 0xFF) + (p & 0xFF);
  }
  return sum / (px.width * 3);
}

double _colBand(IconPixels px, int x) {
  var sum = 0.0;
  for (var y = 0; y < px.height; y++) {
    final p = px.bgra[y * px.width + x];
    sum += ((p >> 16) & 0xFF) + ((p >> 8) & 0xFF) + (p & 0xFF);
  }
  return sum / (px.height * 3);
}
