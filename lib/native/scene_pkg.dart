import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Wallpaper Engine scene packages (`scene.pkg`).
///
/// A scene is rendered by Wallpaper Engine from a package of assets, and the
/// package is a plain container: a table of named blobs (the scene graph, its
/// shaders and models) and, most importantly, the *textures* — the actual
/// artwork, stored either as JPEG/PNG images or as raw/DXT pixel data. The
/// composed scene (layers, parallax, shader effects) only exists inside
/// Wallpaper Engine, but the artwork itself can be pulled out, which beats the
/// author's thumbnail by a wide margin: the backdrop of "Into The Woods" is a
/// 3840×2160 JPEG.
///
/// The formats were verified against a live installation and match what the
/// community tool RePKG reads:
///
///     package:  int32 magicLength, magic ("PKGV0006"), int32 entryCount,
///               per entry: int32 nameLength, name, int32 offset, int32 length
///               (offsets relative to the end of the table)
///     texture:  "TEXV0005\0", "TEXI0001\0", 7 × int32 header
///               (format, flags, textureW, textureH, imageW, imageH, unk),
///               "TEXB000x\0", int32 imageCount, [v3+: imageFormat],
///               [v4+: isVideo], per image: int32 mipCount, per mipmap:
///               [v4: 3 ints + string], int32 width, int32 height,
///               [v2+: int32 isLz4, int32 decompressedLength],
///               int32 byteCount, bytes

/// The container and texture layouts are documented on [extractSceneBackdrop].
/// Texture pixel formats (RePKG's TexFormat).
const _formatRgba8888 = 0;
const _formatDxt5 = 4;
const _formatDxt3 = 6;
const _formatDxt1 = 7;

/// One blob of the package table.
class SceneEntry {
  const SceneEntry(this.name, this.offset, this.length);

  final String name;

  /// Relative to the end of the table.
  final int offset;
  final int length;
}

/// A texture that carries a payload we can turn into a picture.
class SceneTexture {
  const SceneTexture({
    required this.name,
    required this.width,
    required this.height,
    required this.format,
    required this.payloadOffset,
    required this.payloadLength,
    required this.lz4,
    required this.decompressedLength,
    this.isVideo = false,
  });

  final String name;
  final int width;
  final int height;

  /// [ScenePackage] texFormat of the whole texture (RGBA8888 / DXT…).
  final int format;

  /// Where the first mipmap's bytes live inside the texture blob.
  final int payloadOffset;
  final int payloadLength;

  /// Payload is LZ4 (block format) compressed; [decompressedLength] is its
  /// size once expanded.
  final bool lz4;
  final int decompressedLength;

  /// The package labels this texture as an MP4 (`isVideoMp4` in the v4
  /// container): the payload is a video, and the scene's motion for that layer
  /// can be played directly.
  final bool isVideo;

  int get pixelCount => width * height;

  /// JPEG and PNG payloads are already pictures; RGBA8888 is raw pixels.
  String get payloadKind {
    if (lz4) return 'lz4';
    if (format == _formatRgba8888 || format == 8 || format == 9) return 'raw';
    if (format == _formatDxt5 ||
        format == _formatDxt3 ||
        format == _formatDxt1) {
      return 'dxt';
    }
    return 'image';
  }
}

/// Parses the package table. [head] only needs to hold the table itself
/// (a few KB); returns null when this is not a Wallpaper Engine package.
/// [dataStart] is the base every entry offset is relative to.
({List<SceneEntry> entries, int dataStart})? parseSceneTable(Uint8List head) {
  final data = ByteData.sublistView(head);
  if (head.length < 16) return null;
  final magicLength = data.getInt32(0, Endian.little);
  if (magicLength < 4 || magicLength > 32 || 4 + magicLength + 4 > head.length) {
    return null;
  }
  final magic = String.fromCharCodes(head.sublist(4, 4 + magicLength));
  if (!magic.startsWith('PKGV')) return null;
  var p = 4 + magicLength;
  final count = data.getInt32(p, Endian.little);
  p += 4;
  if (count < 0 || count > 100000) return null;

  final entries = <SceneEntry>[];
  for (var i = 0; i < count; i++) {
    if (p + 4 > head.length) return null;
    final nameLength = data.getInt32(p, Endian.little);
    p += 4;
    if (nameLength < 0 || nameLength > 4096 || p + nameLength + 8 > head.length) {
      return null;
    }
    final name = String.fromCharCodes(head.sublist(p, p + nameLength));
    p += nameLength;
    final offset = data.getInt32(p, Endian.little);
    p += 4;
    final length = data.getInt32(p, Endian.little);
    p += 4;
    if (offset < 0 || length < 0) return null;
    entries.add(SceneEntry(name, offset, length));
  }
  return (entries: entries, dataStart: p);
}

/// Parses one `TEXV…` texture blob. Returns null for payloads this reader
/// cannot turn into a picture (DXT, video, cubemap wrappers it does not need).
///
/// [headerOnly] skips the check that the payload bytes are present: the caller
/// has only read the front of the blob (the header is all this needs) and will
/// fetch the payload itself if this texture is the one it wants.
SceneTexture? parseSceneTexture(Uint8List blob, String name,
    {bool headerOnly = false}) {
  final data = ByteData.sublistView(blob);
  var p = 0;
  String? readNString({int maxLength = 16}) {
    // A NUL-terminated string, as the engine stores its magics.
    final start = p;
    while (p < blob.length && blob[p] != 0) {
      p++;
    }
    if (p >= blob.length || p - start > maxLength) return null;
    final text = String.fromCharCodes(blob.sublist(start, p));
    p++; // the NUL
    return text;
  }

  final magic1 = readNString();
  if (magic1 == null || !magic1.startsWith('TEXV')) return null;
  final magic2 = readNString();
  if (magic2 == null || !magic2.startsWith('TEXI')) return null;
  if (p + 28 > blob.length) return null;

  final format = data.getInt32(p, Endian.little);
  // Six more header fields follow the format: flags, the padded texture size,
  // the image size, and an unknown int. (Reading them one by one is how this
  // was off by one int32 the first time.)
  p += 28;

  final container = readNString();
  if (container == null || !container.startsWith('TEXB')) return null;
  final version = int.tryParse(container.substring(4)) ?? 0;
  if (p + 4 > blob.length) return null;
  p += 4; // imageCount — image 0 is enough for a still
  if (version >= 3) p += 4; // imageFormat (JPEG/PNG/…)
  var isVideo = false;
  if (version >= 4) {
    if (p + 4 > blob.length) return null;
    isVideo = data.getInt32(p, Endian.little) != 0;
    p += 4;
  }
  if (p + 4 > blob.length) return null;
  p += 4; // mipmap count

  if (version >= 4) {
    // Four extra fields RePKG treats as unconfirmed editor parameters, one of
    // which is a condition string that can be long.
    if (p + 8 > blob.length) return null;
    p += 8;
    final condition = readNString(maxLength: 8192);
    if (condition == null) return null;
    p += 4;
  }
  if (p + 8 > blob.length) return null;
  final width = data.getInt32(p, Endian.little);
  p += 4;
  final height = data.getInt32(p, Endian.little);
  p += 4;
  var lz4 = false;
  var decompressed = 0;
  if (version >= 2) {
    if (p + 8 > blob.length) return null;
    lz4 = data.getInt32(p, Endian.little) == 1;
    p += 4;
    decompressed = data.getInt32(p, Endian.little);
    p += 4;
  }
  if (p + 4 > blob.length) return null;
  final byteCount = data.getInt32(p, Endian.little);
  p += 4;
  if (width <= 0 || height <= 0 || byteCount <= 0) return null;
  if (!headerOnly && p + byteCount > blob.length) return null;

  return SceneTexture(
    name: name,
    width: width,
    height: height,
    format: format,
    payloadOffset: p,
    payloadLength: byteCount,
    lz4: lz4,
    decompressedLength: decompressed,
    isVideo: isVideo,
  );
}

/// Names that are never the wallpaper's picture: material maps and masks.
final _notAPicture = RegExp(
  r'normal|(_|/)nrm|mask|noise|glow|height|rough|metal|specular|depth|'
  r'alpha|blur|distort|refract|shadow|_r8|_rg',
  caseSensitive: false,
);

/// Picks the texture that will look most like the wallpaper: a landscape
/// picture big enough for a window, preferring the largest. When the package
/// holds no landscape picture at all, the largest *any-shape* texture wins —
/// square 4K artwork ("Samurai Girl") beats the author's small preview even
/// though it is not shaped like a monitor. Returns null when nothing suitable
/// is in the package (the caller falls back to the preview).
SceneTexture? pickBackdrop(List<SceneTexture> textures) {
  SceneTexture? landscape;
  SceneTexture? anyShape;
  for (final texture in textures) {
    if (texture.payloadKind == 'dxt') continue;
    if (texture.width < 1024) continue;
    if (_notAPicture.hasMatch(texture.name)) continue;
    final aspect = texture.height == 0 ? 0.0 : texture.width / texture.height;
    if (aspect >= 1.3 && aspect <= 2.7) {
      if (landscape == null || texture.pixelCount > landscape.pixelCount) {
        landscape = texture;
      }
    } else if (aspect >= 0.5 && aspect <= 4.0) {
      // A portrait or square picture is still the wallpaper's own artwork.
      if (anyShape == null || texture.pixelCount > anyShape.pixelCount) {
        anyShape = texture;
      }
    }
  }
  return landscape ?? anyShape;
}

/// LZ4 block-format decompression into a buffer of [length] bytes.
Uint8List? lz4BlockDecode(Uint8List source, int length) {
  if (length <= 0 || length > 512 * 1024 * 1024) return null;
  final out = Uint8List(length);
  var s = 0;
  var d = 0;
  while (s < source.length) {
    final token = source[s++];
    var literals = token >> 4;
    if (literals == 15) {
      int extra;
      do {
        if (s >= source.length) return null;
        extra = source[s++];
        literals += extra;
      } while (extra == 255);
    }
    if (s + literals > source.length || d + literals > length) return null;
    out.setRange(d, d + literals, source, s);
    s += literals;
    d += literals;
    if (s >= source.length) break; // last sequence has no match
    if (s + 2 > source.length) return null;
    final offset = source[s] | (source[s + 1] << 8);
    s += 2;
    if (offset == 0 || offset > d) return null;
    var matchLength = token & 0xF;
    if (matchLength == 15) {
      int extra;
      do {
        if (s >= source.length) return null;
        extra = source[s++];
        matchLength += extra;
      } while (extra == 255);
    }
    matchLength += 4;
    if (d + matchLength > length) return null;
    var from = d - offset;
    for (var i = 0; i < matchLength; i++) {
      out[d++] = out[from++];
    }
  }
  return d == length ? out : null;
}

/// Extracts the wallpaper's picture from the scene package at [pkgPath] and
/// writes it next to [outBase] (`outBase.jpg` or `outBase.png`, depending on
/// how the artwork is stored). Returns the written path, or null when the
/// package holds no usable picture. Blocking: call it on a worker isolate.
String? extractSceneBackdrop(String pkgPath, String outBase) {
  final file = File(pkgPath);
  if (!file.existsSync()) return null;
  final size = file.lengthSync();
  if (size < 64) return null;

  final raf = file.openSync();
  try {
    final head = _readAt(raf, 0, size < 262144 ? size : 262144);
    final table = parseSceneTable(head);
    if (table == null) return null;
    final dataStart = table.dataStart;

    // The backdrop is the biggest asset in the package; walk the .tex entries
    // from the largest down and take the first one that turns into a picture.
    final texes = table.entries.where((e) => e.name.endsWith('.tex')).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final candidates = <SceneTexture>[];
    for (final entry in texes.take(_candidateScan)) {
      if (entry.length < 4096 || entry.length > 96 * 1024 * 1024) continue;
      final start = dataStart + entry.offset;
      if (start < 0 || start + entry.length > size) continue;
      // Only the header is read to judge a candidate. Reading the whole blob
      // meant up to twelve full textures (each capped at 96 MB) pulled off the
      // disk to parse a few hundred bytes — and the ones this reader cannot
      // use anyway are usually the biggest ones in the package.
      final probe = _readAt(raf, start, entry.length < _headerProbe ? entry.length : _headerProbe);
      final texture = parseSceneTexture(probe, entry.name, headerOnly: true);
      if (texture == null) continue;
      candidates.add(texture);
      if (!_looksLikeBackdrop(texture)) continue;
      final written = _writeTexture(raf, start, texture, entry.length, outBase);
      if (written != null) return written;
    }

    // Nothing claimed to be a picture: fall back to whatever decodes.
    final backdrop = pickBackdrop(candidates);
    if (backdrop == null) return null;
    final entry = texes.firstWhere((e) => e.name == backdrop.name);
    return _writeTexture(
        raf, dataStart + entry.offset, backdrop, entry.length, outBase);
  } catch (_) {
    return null;
  } finally {
    raf.closeSync();
  }
}

/// How much of a texture is read to parse its header: the magic, the fixed
/// header fields and the condition string (which is bounded by 8 KB) all live
/// in the front of the blob.
const _headerProbe = 32 * 1024;

/// Writes [texture]'s payload as a picture, reading only the payload range out
/// of the package at [base]. Returns null for payloads that are not pictures
/// (DXT blocks, video, cubemap wrappers).
String? _writeTexture(RandomAccessFile raf, int base, SceneTexture texture,
    int blobLength, String outBase) {
  if (texture.payloadOffset + texture.payloadLength > blobLength) return null;
  var payload = _readAt(raf, base + texture.payloadOffset, texture.payloadLength);
  if (payload.length < texture.payloadLength) return null;
  if (texture.lz4) {
    payload = lz4BlockDecode(payload, texture.decompressedLength) ?? payload;
  }
  if (payload.length < 8) return null;

  // JPEG / PNG payloads are already pictures.
  if (payload[0] == 0xFF && payload[1] == 0xD8) {
    final out = '$outBase.jpg';
    File(out).writeAsBytesSync(payload);
    return out;
  }
  if (payload[0] == 0x89 && payload[1] == 0x50) {
    final out = '$outBase.png';
    File(out).writeAsBytesSync(payload);
    return out;
  }

  // Raw RGBA pixels: turn them into a PNG. The biggest ones (8K) are resized
  // down first — encoding 134 MB of pixels takes a second and the window
  // never shows more than 2.5K across.
  if (texture.format != _formatRgba8888) return null;
  final expected = texture.width * texture.height * 4;
  if (payload.length < expected) return null;
  // A backdrop is opaque, and the reader has always dropped the alpha channel
  // (the old per-pixel path wrote into a three-channel image). Forcing it here
  // keeps that — one 32-bit store per pixel, on the payload copy that was made
  // anyway — instead of a per-pixel repaint of all four channels.
  final pixelCount = texture.width * texture.height;
  final pixels = Uint32List.view(payload.buffer, payload.offsetInBytes, pixelCount);
  for (var i = 0; i < pixelCount; i++) {
    pixels[i] |= 0xFF000000;
  }
  // Wrapping the bytes beats a per-pixel loop: 8.3 M `setPixelRgba` calls for a
  // 4K texture, 33 M for an 8K one.
  var image = img.Image.fromBytes(
    width: texture.width,
    height: texture.height,
    bytes: payload.buffer,
    bytesOffset: payload.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  const maxWidth = 2560;
  if (image.width > maxWidth) {
    image = img.copyResize(image,
        width: maxWidth,
        height: (image.height * maxWidth / image.width).round(),
        interpolation: img.Interpolation.average);
  }
  final out = '$outBase.png';
  File(out).writeAsBytesSync(img.encodePng(image));
  return out;
}

bool _looksLikeBackdrop(SceneTexture texture) {
  if (texture.width < 1024) return false;
  final aspect = texture.width / texture.height;
  if (aspect < 1.3 || aspect > 2.7) return false;
  return !_notAPicture.hasMatch(texture.name);
}

/// Biggest textures first, top-down, as far as a picture can plausibly hide.
const _candidateScan = 12;

/// Reads exactly [length] bytes (a single `readSync` may come up short).
Uint8List _readAt(RandomAccessFile file, int start, int length) {
  file.setPositionSync(start);
  final out = Uint8List(length);
  var filled = 0;
  while (filled < length) {
    final chunk = file.readSync(length - filled);
    if (chunk.isEmpty) break;
    out.setRange(filled, filled + chunk.length, chunk);
    filled += chunk.length;
  }
  return filled == length ? out : Uint8List.sublistView(out, 0, filled);
}
