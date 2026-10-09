import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'win32_api.dart';

/// Encodes top-down BGRA pixels as a PNG.
///
/// Shell bitmaps arrive premultiplied, PNG wants straight alpha, so partially
/// transparent pixels are un-premultiplied here. When the bitmap carries no
/// alpha at all (classic icons) transparency comes from the 1bpp [IconPixels]
/// mask instead; 1 = transparent there.
Uint8List? encodeBgraPng(IconPixels px) {
  final mask = px.mask;
  var hasAlpha = false;
  for (final p in px.bgra) {
    if ((p >> 24) != 0) {
      hasAlpha = true;
      break;
    }
  }

  // Four channels: without this the alpha written below is dropped and every
  // icon lands as an opaque square.
  final image = img.Image(width: px.width, height: px.height, numChannels: 4);
  final data = image.data;
  if (data == null) return null;
  // Written straight into the image's own bytes. A four-channel uint8 image is
  // four bytes per pixel in RGBA order — exactly the layout the per-pixel
  // `setPixelRgba` writes — and skipping the calls skips a method dispatch, a
  // bounds check and two `num` conversions per channel.
  final bytes = data.toUint8List();
  final width = px.width;
  final height = px.height;
  final maskRowBytes = px.maskRowBytes;
  var i = 0;
  var o = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++, i++, o += 4) {
      final p = px.bgra[i];
      var b = p & 0xFF;
      var g = (p >> 8) & 0xFF;
      var r = (p >> 16) & 0xFF;
      var a = hasAlpha ? (p >> 24) & 0xFF : 0xFF;
      if (!hasAlpha && mask != null) {
        final byte = mask[y * maskRowBytes + (x >> 3)];
        final bit = (byte >> (7 - (x & 7))) & 1;
        a = bit == 0 ? 0xFF : 0x00;
      } else if (a != 0 && a != 255) {
        r = (r * 255 ~/ a).clamp(0, 255);
        g = (g * 255 ~/ a).clamp(0, 255);
        b = (b * 255 ~/ a).clamp(0, 255);
      }
      bytes[o] = r;
      bytes[o + 1] = g;
      bytes[o + 2] = b;
      bytes[o + 3] = a;
    }
  }
  // encodePng already returns a Uint8List; wrapping it again copied the whole
  // PNG (megabytes, for a full-size frame) for nothing.
  return img.encodePng(image);
}
