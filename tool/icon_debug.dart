// Dev-only: step-by-step icon extraction debugging.
import 'dart:io';


import 'package:image/image.dart' as img;

import 'package:xgame_desktop/native/win32_api.dart';

void main(List<String> args) {
  final path = args.isNotEmpty
      ? args[0]
      : r'C:\Windows\System32\notepad.exe';
  stdout.writeln('target: $path');

  final hicon = extractIconHandle(path, 48);
  stdout.writeln('extractIconHandle -> $hicon');
  if (hicon == 0) {
    final resolved = shGetFileIcon(path);
    stdout.writeln('shGetFileIcon -> $resolved');
    return;
  }

  final px = hiconToBgra(hicon);
  stdout.writeln('hiconToBgra -> ${px == null ? "<null>" : "${px.width}x${px.height}"}');
  if (px == null) return;

  var hasAlpha = false;
  for (final p in px.bgra) {
    if ((p >> 24) != 0) {
      hasAlpha = true;
      break;
    }
  }
  stdout.writeln('hasAlpha=$hasAlpha');

  final image = img.Image(width: px.width, height: px.height);
  final data = image.data;
  stdout.writeln('image.data = $data');
  if (data == null) return;
  for (var y = 0; y < px.height; y++) {
    for (var x = 0; x < px.width; x++) {
      final i = y * px.width + x;
      final p = px.bgra[i];
      var b = p & 0xFF, g = (p >> 8) & 0xFF, r = (p >> 16) & 0xFF;
      var a = hasAlpha ? (p >> 24) & 0xFF : 0xFF;
      if (!hasAlpha) {
        final byte = px.mask![y * px.maskRowBytes + (x ~/ 8)];
        final bit = (byte >> (7 - (x % 8))) & 1;
        a = bit == 0 ? 0xFF : 0x00;
      } else if (a != 0 && a != 255) {
        r = (r * 255 ~/ a).clamp(0, 255);
        g = (g * 255 ~/ a).clamp(0, 255);
        b = (b * 255 ~/ a).clamp(0, 255);
      }
      data.setPixelRgba(x, y, r, g, b, a);
    }
  }
  final png = img.encodePng(image);
  stdout.writeln('png bytes=${png.length}');
  File('icon_debug.png').writeAsBytesSync(png);
  stdout.writeln('written icon_debug.png');
}
