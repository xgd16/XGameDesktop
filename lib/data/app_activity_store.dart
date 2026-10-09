import 'package:sqlite3/sqlite3.dart';

import 'sqlite_transaction.dart';

/// One app's launch history — a row of `app_usage`.
class LaunchRecord {
  const LaunchRecord({
    required this.key,
    required this.name,
    required this.launches,
    this.firstLaunch,
    this.lastLaunch,
    required this.createTime,
    required this.updateTime,
  });

  /// The app's path, lower-cased. This is the row's key, and the same key the
  /// pinned rows use, so a Steam game's `steam://` path counts like a shortcut.
  final String key;

  /// The name last seen for it. Kept here rather than looked up, so an app that
  /// has since been uninstalled still reads as something in the statistics.
  /// Empty for the counts imported from `usage.json`, which never carried one.
  final String name;

  /// How many times it has been opened.
  final int launches;

  /// When it was first and last opened. Null for launches counted before this
  /// build, and for the imported counts — the old file kept no times.
  final DateTime? firstLaunch;
  final DateTime? lastLaunch;

  /// When the row was first written, and when it last changed.
  final DateTime createTime;
  final DateTime updateTime;

  /// [name] when the row has one, otherwise the file name out of [key] — the
  /// legible stand-in for an app whose row predates the name column, or whose
  /// shortcut is gone.
  String get displayName {
    if (name.isNotEmpty) return name;
    final cut = key.lastIndexOf(RegExp(r'[\\/]'));
    final file = cut >= 0 ? key.substring(cut + 1) : key;
    final dot = file.lastIndexOf('.');
    final stem = dot > 0 ? file.substring(0, dot) : file;
    return stem.isEmpty ? key : stem;
  }

  static LaunchRecord fromRow(Row row) => LaunchRecord(
        key: row['app_key'] as String,
        name: row['name'] as String,
        launches: row['launches'] as int,
        firstLaunch: _time(row['first_launch']),
        lastLaunch: _time(row['last_launch']),
        createTime: _time(row['create_time'])!,
        updateTime: _time(row['update_time'])!,
      );

  static DateTime? _time(Object? millis) => millis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(millis as int, isUtc: true);

  @override
  String toString() => 'LaunchRecord($key: ${launches}x)';
}

/// The per-app activity tables: how often each app has been opened
/// (`app_usage`), and which ones are pinned and in what order (`app_pin`).
///
/// Both are keyed by the lower-cased app path — the same key [LaunchRecord.key]
/// carries — which is what lets a launch be recorded before the catalog has
/// even been scanned.
class AppActivityStore {
  AppActivityStore(this._db, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// The launch history table.
  static const String usageTable = 'app_usage';

  /// The pinned-apps table.
  static const String pinTable = 'app_pin';

  final Database _db;
  final DateTime Function() _clock;

  int _now() => _clock().toUtc().millisecondsSinceEpoch;

  // ---- launch history ----

  /// Every app that has been launched at least once, most launched first and
  /// by name within a tie.
  List<LaunchRecord> launches() => _db
      .select('SELECT app_key, name, launches, first_launch, last_launch, '
          'create_time, update_time FROM $usageTable '
          'ORDER BY launches DESC, name COLLATE NOCASE, app_key')
      .map(LaunchRecord.fromRow)
      .toList(growable: false);

  /// The row for [key], or null when that app has never been launched.
  LaunchRecord? launch(String key) {
    final rows = _db.select(
      'SELECT app_key, name, launches, first_launch, last_launch, '
      'create_time, update_time FROM $usageTable WHERE app_key = ?',
      [key],
    );
    return rows.isEmpty ? null : LaunchRecord.fromRow(rows.first);
  }

  /// Every launch ever recorded, across every app.
  int get totalLaunches {
    final rows = _db.select('SELECT COALESCE(SUM(launches), 0) AS total '
        'FROM $usageTable');
    return rows.first['total'] as int;
  }

  /// How many apps have a row at all.
  int get trackedApps => _db
      .select('SELECT COUNT(*) AS n FROM $usageTable')
      .first['n'] as int;

  /// Counts one launch of [key] and hands back the row as it now stands.
  ///
  /// A first launch starts the row; a later one moves the count and
  /// `last_launch` and leaves `first_launch` and `create_time` where they were.
  /// An empty [name] never overwrites a name the row already has.
  LaunchRecord countLaunch(String key, String name) {
    final now = _now();
    _db.execute(
      'INSERT INTO $usageTable '
      '(app_key, name, launches, first_launch, last_launch, create_time, update_time) '
      'VALUES (?, ?, 1, ?, ?, ?, ?) '
      'ON CONFLICT(app_key) DO UPDATE SET '
      'name = CASE WHEN excluded.name = \'\' THEN $usageTable.name '
      'ELSE excluded.name END, '
      'launches = $usageTable.launches + 1, '
      'last_launch = excluded.last_launch, '
      'update_time = excluded.update_time',
      [key, name, now, now, now, now],
    );
    return launch(key)!;
  }

  /// Writes [launches] for [key] outright, rather than adding to it.
  ///
  /// This is the pre-SQLite import's way in, and it is absolute so that an
  /// import which stopped halfway can simply be run again.
  LaunchRecord putLaunch(
    String key, {
    required String name,
    required int launches,
    DateTime? firstLaunch,
    DateTime? lastLaunch,
  }) {
    final now = _now();
    _db.execute(
      'INSERT INTO $usageTable '
      '(app_key, name, launches, first_launch, last_launch, create_time, update_time) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(app_key) DO UPDATE SET '
      'name = CASE WHEN excluded.name = \'\' THEN $usageTable.name '
      'ELSE excluded.name END, '
      'launches = excluded.launches, '
      'first_launch = excluded.first_launch, '
      'last_launch = excluded.last_launch, '
      'update_time = excluded.update_time',
      [
        key,
        name,
        launches,
        firstLaunch?.toUtc().millisecondsSinceEpoch,
        lastLaunch?.toUtc().millisecondsSinceEpoch,
        now,
        now,
      ],
    );
    return launch(key)!;
  }

  /// Throws the whole launch history away. Returns how many apps were dropped.
  int clearLaunches() {
    _db.execute('DELETE FROM $usageTable');
    return _db.updatedRows;
  }

  /// Fills in [name] for [key], leaving the count and the two times alone.
  ///
  /// Only a row that has no name is touched, so this is safe to run on every
  /// launch: the counts imported from `usage.json` carried no name, and the
  /// catalog — which knows one — is only read after the scan.
  LaunchRecord? setLaunchName(String key, String name) {
    if (name.isNotEmpty) {
      _db.execute(
        'UPDATE $usageTable SET name = ?, update_time = ? '
        "WHERE app_key = ? AND name = ''",
        [name, _now(), key],
      );
    }
    return launch(key);
  }

  // ---- pinned apps ----

  /// The pinned apps' keys, front of the grid first.
  List<String> pinned() => _db
      .select('SELECT app_key FROM $pinTable ORDER BY position')
      .map((row) => row['app_key'] as String)
      .toList(growable: false);

  /// Makes the table hold exactly [keys], in that order.
  ///
  /// The in-memory list is the arrangement's source of truth — pinning,
  /// unpinning and stepping a row along all edit it — so this mirrors it back
  /// rather than offering a second way to move one row. A row that keeps its
  /// place keeps its `update_time`.
  void setPins(List<String> keys) {
    final now = _now();
    _db.transaction(() {
      if (keys.isEmpty) {
        _db.execute('DELETE FROM $pinTable');
        return;
      }
      final marks = List.filled(keys.length, '?').join(', ');
      _db.execute('DELETE FROM $pinTable WHERE app_key NOT IN ($marks)', keys);
      for (var i = 0; i < keys.length; i++) {
        _db.execute(
          'INSERT INTO $pinTable (app_key, position, create_time, update_time) '
          'VALUES (?, ?, ?, ?) '
          'ON CONFLICT(app_key) DO UPDATE SET '
          'position = excluded.position, '
          'update_time = CASE WHEN $pinTable.position = excluded.position '
          'THEN $pinTable.update_time ELSE excluded.update_time END',
          [keys[i], i, now, now],
        );
      }
    });
  }
}
