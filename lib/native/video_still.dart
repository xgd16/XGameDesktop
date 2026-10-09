import 'dart:io';

import 'bgra_png.dart';
import 'win32_api.dart';

/// Below this ink coverage the shell handed back its file-type icon instead of
/// a decoded frame. Real frames are opaque edge to edge (1.0); the generic
/// icon is drawn on a transparent square canvas (~0.55-0.70).
const double _minFrameInk = 0.9;

/// COM is per-thread; each isolate that renders frames sets it up once.
bool _comReady = false;

/// Grabs a single frame of [videoPath] through the shell's video thumbnail
/// provider and writes it to [outPath] as a PNG. Returns [outPath], or null
/// when Windows cannot decode a frame (no provider for the format) — the
/// generic file icon is never mistaken for a frame.
///
/// Blocking (100-400 ms typically, dominated by the decoder): call it on a
/// worker isolate. [boxWidth] × [boxHeight] is the size to ask for; the
/// provider decodes at that size, keeping the video's own aspect ratio.
String? renderVideoStill(
  String videoPath,
  String outPath, {
  required int boxWidth,
  required int boxHeight,
}) {
  if (!_comReady) {
    _comReady = true;
    coInitialize();
  }
  // SIIGBF_THUMBNAILONLY is deliberately not set: it only serves already
  // cached thumbnails and fails for everything else. The ink check below is
  // what keeps the icon fallback out.
  final hbmp = shellItemImageHandle(videoPath, boxWidth,
      cy: boxHeight, flags: siigbfBiggerSizeOk);
  if (hbmp == 0) return null;
  try {
    final px = hBitmapToPixels(hbmp);
    if (px == null || _ink(px) < _minFrameInk) return null;
    final png = encodeBgraPng(px);
    if (png == null) return null;
    File(outPath).writeAsBytesSync(png, flush: true);
    return outPath;
  } finally {
    deleteGdiObject(hbmp);
  }
}

/// Fraction of pixels carrying any ink; opaque frames score 1.0.
double _ink(IconPixels px) {
  var ink = 0;
  for (final p in px.bgra) {
    if ((p >> 24) > 8 || (p & 0xFFFFFF) != 0) ink++;
  }
  return ink / (px.width * px.height);
}
