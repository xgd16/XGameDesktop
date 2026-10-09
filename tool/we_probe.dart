// Probe: reads the real Wallpaper Engine installation the way the app does.
//
//   dart run tool/we_probe.dart [file-or-projectJson]
//
// With no argument it reports what WE currently has selected; with a path it
// treats that file (e.g. a workshop .mp4) as the selection instead — handy for
// exercising the video-frame path without touching the user's desktop.
// ignore_for_file: avoid_print, avoid_relative_lib_imports
import 'dart:io';

import '../lib/native/wallpaper_engine.dart';

Future<void> main(List<String> args) async {
  final lib = WallpaperEngineLibrary.locate();
  if (lib == null) {
    print('Wallpaper Engine: not found');
    return;
  }
  print('install : ${lib.installDir}');
  print('config  : ${lib.configPath}');
  print('selected: ${lib.currentFile()}');
  print('steam roots: ${WallpaperEngineLibrary.steamRoots()}');

  final target = args.isNotEmpty ? args[0] : lib.currentFile();
  if (target == null) {
    print('no wallpaper selected');
    return;
  }
  final wallpaper = args.isNotEmpty
      ? WallpaperEngineLibrary.describe(target)
      : lib.current();
  if (wallpaper == null) {
    print('cannot resolve: $target');
    return;
  }
  print('--- wallpaper ---');
  print('title   : ${wallpaper.title}');
  print('type    : ${wallpaper.type} (${wallpaper.typeLabel})');
  print('project : ${wallpaper.projectDir}');
  print('primary : ${wallpaper.primaryFile}');
  print('preview : ${wallpaper.previewPath}');
  print('video?  : ${wallpaper.isVideo}  image? ${wallpaper.isImage}');

  final cache = Directory('${Directory.systemTemp.path}\\xg_we_still');
  cache.createSync(recursive: true);
  final still = await lib.resolveStill(
    wallpaper,
    cacheDir: cache.path,
    boxWidth: 1920,
    boxHeight: 1080,
  );
  if (still == null) {
    print('still   : none');
    return;
  }
  final file = File(still.path);
  print('still   : ${still.kind} -> ${still.path} '
      '(${(file.lengthSync() / 1024).round()}KB)');
}
