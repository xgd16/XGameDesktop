// Builders for synthetic Wallpaper Engine packages, so the scene readers can
// be tested without shipping a game asset. The layouts match the real files.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:typed_data';

/// Builds a package the way Wallpaper Engine does, so the readers can be
/// tested without shipping a game asset.
Uint8List buildPackage(List<(String, Uint8List)> files) {
  final out = BytesBuilder();
  void i32(int value) {
    final b = ByteData(4)..setInt32(0, value, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  i32(8);
  out.add('PKGV0006'.codeUnits);
  i32(files.length);
  var offset = 0;
  for (final (name, bytes) in files) {
    i32(name.length);
    out.add(name.codeUnits);
    i32(offset);
    i32(bytes.length);
    offset += bytes.length;
  }
  for (final (_, bytes) in files) {
    out.add(bytes);
  }
  return out.takeBytes();
}

/// One `TEXV` texture blob. [version] picks the container flavour.
Uint8List buildTexture({
  required int width,
  required int height,
  required List<int> payload,
  int format = 0,
  int version = 3,
  bool lz4 = false,
  int decompressed = 0,
  int imageFormat = 2,
  int headerExtra = 0,
}) {
  final out = BytesBuilder();
  void bytes(List<int> b) => out.add(b);
  void i32(int value) {
    final b = ByteData(4)..setInt32(0, value, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  void nstring(String value) {
    bytes(value.codeUnits);
    out.addByte(0);
  }

  nstring('TEXV0005');
  nstring('TEXI0001');
  i32(format);
  i32(2); // flags
  i32(width);
  i32(height);
  i32(width);
  i32(height);
  i32(0); // unknown
  repeat(int n) {
    for (var i = 0; i < n; i++) {
      out.addByte(0);
    }
  }

  repeat(headerExtra);
  nstring('TEXB000$version');
  i32(1); // image count
  if (version >= 3) i32(imageFormat);
  if (version >= 4) i32(0); // isVideoMp4
  i32(1); // mipmap count
  if (version >= 4) {
    i32(1);
    i32(2);
    nstring('{"condition":"value"}');
    i32(1);
  }
  i32(width);
  i32(height);
  if (version >= 2) {
    i32(lz4 ? 1 : 0);
    i32(lz4 ? (decompressed == 0 ? payload.length : decompressed) : 0);
  }
  i32(payload.length);
  bytes(payload);
  return out.takeBytes();
}

