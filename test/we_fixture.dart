import 'dart:convert';
import 'dart:io';

import 'package:xgame_desktop/native/wallpaper_engine.dart';

/// A fake Steam + Wallpaper Engine tree in a temp folder, laid out exactly the
/// way the live installation is: WE's config.json lives in the app folder and
/// keeps the selection under `<windows user>.general.wallpaperconfig`, while
/// wallpapers live in `steamapps\workshop\content\431960\<id>` next to a
/// project.json.
class SteamTree {
  SteamTree() {
    root = Directory.systemTemp.createTempSync('xg_steam');
    weDir = Directory('${root.path}\\steamapps\\common\\wallpaper_engine')
      ..createSync(recursive: true);
    contentDir =
        Directory('${root.path}\\steamapps\\workshop\\content\\431960')
          ..createSync(recursive: true);
    config = File('${weDir.path}\\config.json');
  }

  late final Directory root;
  late final Directory weDir;
  late final Directory contentDir;
  late final File config;

  /// What the app's locator finds when pointed at this tree. [contentRoots]
  /// keeps the wallpaper scan inside the fake tree — the real lookup would
  /// otherwise walk this machine's Steam libraries.
  WallpaperEngineLibrary get library => WallpaperEngineLibrary(
        installDir: weDir.path,
        configPath: config.path,
        contentRoots: [contentDir.path, myProjects.path, defaultProjects.path],
      );

  Directory get myProjects =>
      Directory('${weDir.path}\\projects\\myprojects')..createSync(recursive: true);

  Directory get defaultProjects =>
      Directory('${weDir.path}\\projects\\defaultprojects')
        ..createSync(recursive: true);

  /// A local (non-workshop) wallpaper, the kind WE keeps under
  /// `wallpaper_engine\projects\myprojects\<name>`.
  Directory localProject(
    String name, {
    required String type,
    required String file,
    String? preview = 'preview.jpg',
    String? title,
    bool declarePreview = true,
  }) {
    final dir = Directory('${myProjects.path}\\$name')..createSync(recursive: true);
    File('${dir.path}\\project.json').writeAsStringSync(jsonEncode({
      'type': type,
      'file': file,
      'title': ?title,
      if (preview != null && declarePreview) 'preview': preview,
    }));
    if (file.isNotEmpty) {
      File('${dir.path}\\${file.split('/').last}')
          .writeAsStringSync('primary-of-$name');
    }
    if (preview != null) {
      File('${dir.path}\\${preview.split('/').last}')
          .writeAsStringSync('preview-of-$name');
    }
    return dir;
  }

  /// Writes a workshop project. [file] is project.json's `file` — a scene
  /// project names `scene.json` there while Wallpaper Engine actually plays
  /// the sibling `scene.pkg`, so pass `createPrimary: false` for those and
  /// carry `scene.pkg` in [extraFiles] (the real folders have no scene.json).
  Directory project(
    String id, {
    required String type,
    required String file,
    String? preview = 'preview.jpg',
    String? title,
    bool createPrimary = true,
    bool declarePreview = true,
    Map<String, String>? extraFiles,
  }) {
    final dir = Directory('${contentDir.path}\\$id')..createSync(recursive: true);
    File('${dir.path}\\project.json').writeAsStringSync(jsonEncode({
      'type': type,
      'file': file,
      'title': ?title,
      if (preview != null && declarePreview) 'preview': preview,
    }));
    if (createPrimary) {
      File('${dir.path}\\${file.split('/').last}')
          .writeAsStringSync('primary-of-$id');
    }
    if (preview != null) {
      File('${dir.path}\\${preview.split('/').last}')
          .writeAsStringSync('preview-of-$id');
    }
    extraFiles?.forEach((name, content) {
      File('${dir.path}\\$name').writeAsStringSync(content);
    });
    return dir;
  }

  /// Selects [file] for one monitor, the way WE's config.json records it.
  void select(
    String file, {
    String monitor = 'Monitor0',
    String? lastSelected,
    List<Map<String, Object?>>? recent,
    String userKey = 'tester',
  }) =>
      selectAll(
        {monitor: file},
        lastSelected: lastSelected,
        recent: recent,
        userKey: userKey,
      );

  void selectAll(
    Map<String, String> monitors, {
    String? lastSelected,
    List<Map<String, Object?>>? recent,
    String userKey = 'tester',
  }) {
    config.writeAsStringSync(jsonEncode({
      '?installdirectory': weDir.path,
      'someone-else': {'unrelated': true},
      userKey: {
        'general': {
          'browser': {
            'lastselectedmonitor': ?lastSelected,
          },
          'wallpaperconfig': {
            'selectedwallpapers': {
              for (final entry in monitors.entries)
                entry.key: {'file': entry.value},
            },
          },
          'wallpaperconfigrecent': ?recent,
        },
      },
    }));
  }

  void dispose() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }
}
