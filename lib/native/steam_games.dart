import 'dart:io';

import 'shell_apps.dart';
import 'wallpaper_engine.dart';

/// Scans Steam's own manifests for the games it has installed. No shortcut is
/// involved — the Start Menu never learns about most Steam games — so the
/// library comes straight from `appmanifest_*.acf` in every Steam library the
/// machine knows about, and launching goes through the `steam://rungameid`
/// protocol, which starts Steam itself when it has to.
class SteamGames {
  SteamGames._();

  /// App ids Steam installs that are not games: the redistributables bundle
  /// and Wallpaper Engine, whose shortcut already reaches the grid by way of
  /// the Start Menu scan.
  static const _excludedAppIds = {228983, 431960};

  /// Manifests that present as installed but are Steam's own plumbing.
  /// Prefixed entries are caught by prefix; the rest by exact name.
  static const _excludedNames = {
    'steam runtime',
    'steam client bootloader',
    'steam client bootstrapper',
    'steamworks common redistributables',
  };

  /// Bit 3 of StateFlags: the content is fully installed and playable. A
  /// download in progress, an update pending — anything else is not something
  /// the grid should offer to launch.
  static const _stateFullyInstalled = 4;

  /// Reads every library's manifests and returns one entry per installed
  /// game, name-sorted. Runs on a background isolate; the registry lookup and
  /// the folder walks are the only system contact, no Steam process needed.
  /// [roots] overrides the registry discovery — the tests' way to point the
  /// scan at a fixture tree.
  static List<AppEntry> scan({List<String>? roots}) {
    final entries = <AppEntry>[];
    final seen = <int>{};
    for (final root in roots ?? WallpaperEngineLibrary.steamRoots()) {
      final steamapps = Directory('$root\\steamapps');
      final List<FileSystemEntity> manifests;
      try {
        manifests = steamapps.listSync();
      } catch (_) {
        continue;
      }
      for (final entity in manifests) {
        if (entity is! File) continue;
        final name =
            entity.path.replaceAll('/', '\\').split('\\').last.toLowerCase();
        if (!name.startsWith('appmanifest_') || !name.endsWith('.acf')) {
          continue;
        }
        final String text;
        try {
          text = entity.readAsStringSync();
        } catch (_) {
          continue;
        }
        final appId = int.tryParse(_field(text, 'appid') ?? '');
        final gameName = _field(text, 'name')?.trim();
        if (appId == null || appId <= 0 || gameName == null) continue;
        if (!seen.add(appId)) continue;
        if (_excludedAppIds.contains(appId)) continue;
        final lowered = gameName.toLowerCase();
        if (_excludedNames.contains(lowered) ||
            lowered.startsWith('steam linux runtime') ||
            lowered.startsWith('proton ')) {
          continue;
        }
        final flags = int.tryParse(_field(text, 'StateFlags') ?? '') ?? 0;
        if (flags & _stateFullyInstalled == 0) continue;
        entries.add(AppEntry(
          name: gameName,
          path: 'steam://rungameid/$appId',
          isGame: true,
          category: AppCategory.game,
          iconFile: _findCover(root, appId),
        ));
      }
    }
    entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return entries;
  }

  /// One quoted value out of an ACF file — the format is a VDF tree, but the
  /// manifests are flat enough that the pair the scan wants (`appid`, `name`,
  /// `StateFlags`) sits at any depth as plain `"key"  "value"` lines.
  static String? _field(String text, String key) {
    final match = RegExp('"$key"\\s+"([^"]*)"').firstMatch(text);
    return match?.group(1);
  }

  /// The cover art Steam itself downloaded, from its library cache: the
  /// portrait first — it is what the cover wall draws — then the landscape
  /// header, in both the per-app folder layout and the flat legacy one.
  /// Null leaves the tile to fetch from the CDN, or to fall back to its
  /// letter block offline.
  static String? _findCover(String root, int appId) {
    final cache = '$root\\appcache\\librarycache';
    final folder = Directory('$cache\\$appId');
    if (folder.existsSync()) {
      for (final name in const [
        'library_600x900.jpg',
        'library_600x900_2x.jpg',
        'header.jpg',
      ]) {
        final file = File('${folder.path}\\$name');
        if (file.existsSync()) return file.path;
      }
    }
    final legacy = File('$cache\\${appId}_header.jpg');
    return legacy.existsSync() ? legacy.path : null;
  }
}
