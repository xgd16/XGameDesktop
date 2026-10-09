// Probe: list what a scene.pkg actually contains — every non-texture entry
// (scene.json, models, shaders) and a texture census (sizes, image counts,
// video flags) — so the animation strategy can be based on facts.
//
//   dart run tool/pkg_dump.dart <scene.pkg> [--json]
//
// ignore_for_file: avoid_print, avoid_relative_lib_imports
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/native/scene_pkg.dart';

void main(List<String> args) {
  final path = args[0];
  final file = File(path);
  final size = file.lengthSync();
  final raf = file.openSync();

  Uint8List readAt(int start, int length) {
    raf.setPositionSync(start);
    final out = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      final chunk = raf.readSync(length - filled);
      if (chunk.isEmpty) break;
      out.setRange(filled, filled + chunk.length, chunk);
      filled += chunk.length;
    }
    return filled == length ? out : Uint8List.sublistView(out, 0, filled);
  }

  try {
    final head = readAt(0, size < 4 * 1024 * 1024 ? size : 4 * 1024 * 1024);
    final table = parseSceneTable(head);
    if (table == null) {
      print('NOT A PKG (or unknown version)');
      return;
    }
    final dataStart = table.dataStart;
    print('entries=${table.entries.length} dataStart=$dataStart '
        'pkgBytes=$size');

    final nonTex = <SceneEntry>[];
    var texCount = 0;
    final texByExt = <String, int>{};
    for (final e in table.entries) {
      final dot = e.name.lastIndexOf('.');
      final ext = dot < 0 ? '(none)' : e.name.substring(dot).toLowerCase();
      if (ext == '.tex') {
        texCount++;
        texByExt[ext] = (texByExt[ext] ?? 0) + 1;
      } else {
        nonTex.add(e);
      }
    }
    print('tex=$texCount  other=$texByExt ${texByExt.keys.join(",")}');
    nonTex.sort((a, b) => b.length.compareTo(a.length));
    print('-- non-texture entries (name / bytes) --');
    for (final e in nonTex.take(60)) {
      print('   ${e.name.padRight(40)} ${e.length}');
    }

    for (final name in ['scene.json', 'scene.pkg.json']) {
      final hit = _find(table.entries, name);
      if (hit == null) continue;
      print('-- $name (${hit.length} bytes) --');
      final bytes = readAt(dataStart + hit.offset, hit.length);
      print(utf8.decode(bytes, allowMalformed: true));
    }

    print('-- texture census --');
    var animated = 0;
    var video = 0;
    var images = 0;
    var parsed = 0;
    final texes = table.entries.where((e) => e.name.endsWith('.tex')).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final e in texes) {
      if (e.length < 64 || dataStart + e.offset + e.length > size) continue;
      final blob = readAt(dataStart + e.offset, e.length);
      final t = parseSceneTexture(blob, e.name);
      if (t == null) continue;
      parsed++;
      if (t.isVideo) video++;
    }
    // Multi-image textures decode as animation frames; counted with a light
    // scan of the TEXB container header.
    for (final e in texes.take(40)) {
      if (e.length < 64 || dataStart + e.offset + e.length > size) continue;
      final blob = readAt(dataStart + e.offset, e.length);
      final n = _imageCount(blob);
      if (n == null) continue;
      images += n;
      if (n > 1) {
        animated++;
        print('   ANIMATED ${e.name} images=$n bytes=${e.length}');
      }
    }
    print('parsed=$parsed videoFlagged=$video multiImageTextures=$animated '
        'sumImages=$images');
  } finally {
    raf.closeSync();
  }
}

SceneEntry? _find(List<SceneEntry> entries, String name) {
  for (final e in entries) {
    if (e.name.toLowerCase() == name) return e;
  }
  return null;
}

/// Walks a TEXV blob far enough to read TEXB's imageCount.
int? _imageCount(Uint8List blob) {
  var p = 0;
  String? readNString() {
    final start = p;
    while (p < blob.length && blob[p] != 0) {
      p++;
    }
    if (p >= blob.length) return null;
    final s = String.fromCharCodes(blob.sublist(start, p));
    p++;
    return s;
  }

  final v = readNString();
  if (v == null || !v.startsWith('TEXV')) return null;
  final i = readNString();
  if (i == null || !i.startsWith('TEXI')) return null;
  if (p + 28 > blob.length) return null;
  p += 28;
  final b = readNString();
  if (b == null || !b.startsWith('TEXB')) return null;
  if (p + 4 > blob.length) return null;
  return ByteData.sublistView(blob).getInt32(p, Endian.little);
}
