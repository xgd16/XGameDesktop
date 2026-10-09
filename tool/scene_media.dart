// Probe: does a scene package hold its own motion? A v4 texture can be an MP4
// (`isVideoMp4`), in which case the scene's main layer can be played directly
// instead of shown as a still.
//
//   dart run tool/scene_media.dart <workshop folder | scene.pkg>
//
// ignore_for_file: avoid_print, avoid_relative_lib_imports
import 'dart:io';
import 'dart:typed_data';

import '../lib/native/scene_pkg.dart';

void main(List<String> args) {
  final files = <File>[];
  final type = FileSystemEntity.typeSync(args[0]);
  if (type == FileSystemEntityType.directory) {
    for (final dir in Directory(args[0]).listSync().whereType<Directory>()) {
      final pkg = File('${dir.path}\\scene.pkg');
      if (pkg.existsSync()) files.add(pkg);
    }
  } else {
    files.add(File(args[0]));
  }

  for (final pkg in files) {
    final id = pkg.parent.path.split(RegExp(r'[\\/]')).last;
    final raf = pkg.openSync();
    try {
      final size = pkg.lengthSync();
      final head = _read(raf, 0, size < 262144 ? size : 262144);
      final table = parseSceneTable(head);
      if (table == null) {
        print('$id: not a package');
        continue;
      }
      final texes = table.entries.where((e) => e.name.endsWith('.tex')).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      final lines = <String>[];
      final parsed = <SceneTexture>[];
      var hasVideoPayload = 0;
      for (final entry in texes.take(10)) {
        final blob = _read(raf, table.dataStart + entry.offset, entry.length);
        final texture = parseSceneTexture(blob, entry.name);
        if (texture == null) {
          lines.add('    ${entry.name}  <unparsed> ${entry.length ~/ 1024}KB');
          continue;
        }
        parsed.add(texture);
        final isFtyp = blob.length > texture.payloadOffset + 12 &&
            String.fromCharCodes(blob.sublist(
                    texture.payloadOffset + 4, texture.payloadOffset + 8)) ==
                'ftyp';
        if (texture.isVideo || isFtyp) hasVideoPayload++;
        lines.add('    ${entry.name}  ${texture.width}x${texture.height} '
            'fmt=${texture.format} ${texture.payloadKind}'
            '${texture.isVideo ? ' VIDEO' : ''}'
            '${isFtyp ? ' ftyp-mp4' : ''}'
            '  ${entry.length ~/ 1024}KB');
      }
      final picked = pickBackdrop(parsed);
      print('$id  tex=${texes.length}  '
          'backdrop=${picked?.name ?? '-'} '
          '(video=${picked?.isVideo ?? false}, '
          '${picked?.width ?? 0}x${picked?.height ?? 0})  '
          'videoPayloads=$hasVideoPayload');
      for (final line in lines) {
        print(line);
      }
    } catch (e) {
      print('$id: $e');
    } finally {
      raf.closeSync();
    }
  }
}

Uint8List _read(RandomAccessFile file, int start, int length) {
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
