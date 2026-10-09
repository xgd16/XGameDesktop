import 'dart:convert';
import 'dart:io';

import '../data/app_activity_store.dart';

/// Copies a pre-SQLite `usage.json` and `pins.json` into the `app_usage` and
/// `app_pin` tables.
///
/// `usage.json` was `{app path: launches}` — a count and nothing else, with no
/// name for the app and no record of when any of it happened. Those rows are
/// imported with the count alone: the statistics page lists them and leaves
/// "最后启动" blank, which is the truth rather than a guess. The name is filled
/// in from the catalog while the app is still installed, and read off the path
/// when it is not (see [LaunchRecord.displayName]).
///
/// `pins.json` was the pinned keys in grid order, which is exactly the
/// `position` column.
///
/// Both writes are absolute, so a run that stopped halfway can be repeated.
void importLegacyAppActivity(AppActivityStore store, Directory dataDir) {
  final usage = _readJson(File('${dataDir.path}\\usage.json'));
  if (usage is Map) {
    for (final entry in usage.entries) {
      final key = entry.key;
      final count = entry.value;
      if (key is! String || key.isEmpty) continue;
      if (count is! int || count <= 0) continue;
      store.putLaunch(key.toLowerCase(), name: '', launches: count);
    }
  }

  final pins = _readJson(File('${dataDir.path}\\pins.json'));
  if (pins is List) {
    store.setPins([
      for (final key in pins)
        if (key is String && key.isNotEmpty) key.toLowerCase(),
    ]);
  }
}

/// The old file's contents, or null when there is no file or it does not hold
/// JSON. Neither is worth failing a launch over.
Object? _readJson(File file) {
  if (!file.existsSync()) return null;
  try {
    return jsonDecode(file.readAsStringSync());
  } catch (_) {
    return null;
  }
}
