import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xgame_desktop/native/bgra_png.dart';

/// The icon encoder writes straight into the image's own bytes (a four-channel
/// uint8 image is RGBA in memory), so these pin the layout it assumes: BGRA in,
/// straight-alpha RGBA out.
void main() {
  /// One pixel as (r, g, b, a) after a round trip through PNG.
  (int, int, int, int) pixelAt(img.Image image, int x, int y) {
    final p = image.getPixel(x, y);
    return (p.r.toInt(), p.g.toInt(), p.b.toInt(), p.a.toInt());
  }

  img.Image decode(Uint8List png) => img.decodePng(png)!;

  test('BGRA 逐通道对应，预乘的半透明像素还原成直 alpha', () {
    final pixels = encodeBgraPng((
      width: 2,
      height: 1,
      // 0xAARRGGBB as a uint32: alpha in the top byte, then red, green, blue.
      bgra: Uint32List.fromList([
        0xFFFF0000, // opaque red
        0x80400000, // premultiplied red at half alpha → straight 127
      ]),
      mask: null,
      maskRowBytes: 0,
    ))!;
    final image = decode(pixels);
    expect(image.width, 2);
    expect(image.height, 1);
    expect(pixelAt(image, 0, 0), (255, 0, 0, 255));
    expect(pixelAt(image, 1, 0), (127, 0, 0, 128));
  });

  test('没有 alpha 通道时，透明由 1bpp 掩码决定（1 = 透明）', () {
    // Two pixels: the first is inked (mask bit 0), the second is not.
    final pixels = encodeBgraPng((
      width: 2,
      height: 1,
      bgra: Uint32List.fromList([0x00FF0000, 0x0000FF00]),
      mask: Uint8List.fromList([0x40]), // 0b0100_0000 → bit0=0, bit1=1
      maskRowBytes: 1,
    ))!;
    final image = decode(pixels);
    expect(pixelAt(image, 0, 0), (255, 0, 0, 255));
    expect(pixelAt(image, 1, 0), (0, 255, 0, 0));
  });

  test('掩码按行字节排列，跨行不会串位', () {
    final pixels = encodeBgraPng((
      width: 8,
      height: 2,
      bgra: Uint32List.fromList(List.filled(16, 0x00FFFFFF)),
      // A set bit is transparent: row 0 is all transparent, row 1 is
      // transparent but for its last pixel (bit 0 = 0 there).
      mask: Uint8List.fromList([0xFF, 0xFE]),
      maskRowBytes: 1,
    ))!;
    final image = decode(pixels);
    for (var x = 0; x < 8; x++) {
      expect(pixelAt(image, x, 0).$4, 0, reason: '第一行整行透明');
    }
    for (var x = 0; x < 7; x++) {
      expect(pixelAt(image, x, 1).$4, 0, reason: '第二行只有最后一格不透明');
    }
    expect(pixelAt(image, 7, 1), (255, 255, 255, 255));
  });
}
