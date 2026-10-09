// Probe: pull the wallpaper's own artwork out of scene.pkg files (the biggest
// landscape texture), write it to a temp folder and report what came out.
//
//   dart run tool/pkg_probe.dart <scene.pkg | workshop folder> [outDir]
//
// ignore_for_file: avoid_print, avoid_relative_lib_imports
import 'dart:io';

import 'package:image/image.dart' as img;

import '../lib/native/scene_pkg.dart';

void main(List<String> args) {
  final target = args[0];
  final outDir = Directory(args.length > 1
      ? args[1]
      : '${Directory.systemTemp.path}\\xg_scene_stills')
    ..createSync(recursive: true);

  final files = <File>[];
  if (FileSystemEntity.typeSync(target) == FileSystemEntityType.directory) {
    for (final dir in Directory(target).listSync().whereType<Directory>()) {
      final pkg = File('${dir.path}\\scene.pkg');
      if (pkg.existsSync()) files.add(pkg);
    }
  } else {
    files.add(File(target));
  }

  for (final pkg in files) {
    final id = pkg.parent.path.split(RegExp(r'[\\/]')).last;
    final outBase = '${outDir.path}\\$id';
    if (args.contains('--debug')) {
      final head = pkg.openSync();
      final bytes = head.readSync(pkg.lengthSync() < 262144 ? pkg.lengthSync() : 262144);
      head.closeSync();
      final table = parseSceneTable(bytes);
      if (table == null) {
        print('${id.padRight(12)} table=null  '
            'magicLen=${bytes.length >= 4 ? bytes[0] : -1}');
        continue;
      }
      final texes = table.entries.where((e) => e.name.endsWith('.tex')).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      print('${id.padRight(12)} entries=${table.entries.length} '
          'dataStart=${table.dataStart} tex=${texes.length}');
      for (final e in texes.take(3)) {
        print('    ${e.name}  off=${e.offset} len=${e.length}');
      }
      final first = texes.first;
      final blob = pkg
          .openSync()
        ..setPositionSync(table.dataStart + first.offset);
      final entryBytes = blob.readSync(first.length);
      print("    read ${entryBytes.length} of ${first.length}");
      blob.closeSync();
      final texture = parseSceneTexture(entryBytes, first.name);
      if (texture == null) {
        print('    parseSceneTexture=null (first 24 bytes: '
            '${entryBytes.take(24).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')})');
      } else {
        print('    tex ${texture.width}x${texture.height} fmt=${texture.format} '
            'kind=${texture.payloadKind} lz4=${texture.lz4} '
            'payload=${texture.payloadOffset}+${texture.payloadLength} '
            'magic=${entryBytes.sublist(texture.payloadOffset, texture.payloadOffset + 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      }
      continue;
    }
    final sw = Stopwatch()..start();
    final written = extractSceneBackdrop(pkg.path, outBase);
    sw.stop();
    if (written == null) {
      print('${id.padRight(12)} MISS  (${pkg.lengthSync() ~/ 1024}KB, '
          '${sw.elapsedMilliseconds}ms)');
      continue;
    }
    final file = File(written);
    var dims = '?';
    try {
      final decoded = img.decodeImage(file.readAsBytesSync());
      dims = decoded == null ? '??' : '${decoded.width}x${decoded.height}';
    } catch (_) {}
    print('${id.padRight(12)} OK    $dims  '
        '${file.lengthSync() ~/ 1024}KB  ${sw.elapsedMilliseconds}ms  '
        '-> ${file.path.split(RegExp(r'[\\/]')).last}');
  }
}
