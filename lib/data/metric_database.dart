import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'metric_store.dart';

/// The metrics database: the seven-day history of device readings, in a file
/// of its own (`metrics.db`) beside the profile database.
///
/// Apart from `xgame.db` on purpose. A sample every three seconds is a couple
/// of hundred thousand rows a week — a different order of magnitude from the
/// profile's settings and launch counts, and a table that is *meant* to be
/// thrown away: deleting the file (or the page's 清空记录) loses readings and
/// nothing else. Its own connection also means a long bucketing read never
/// holds the write lock the profile's tables share.
class MetricDatabase {
  MetricDatabase._(this.db, this.path);

  /// The file the device history lives in.
  static const String fileName = 'metrics.db';

  /// What `user_version` reads once the schema below is in place.
  ///
  /// 1. the `metric_sample` table
  static const int schemaVersion = 1;

  /// The open connection. Callers hand this to a store and leave it alone.
  final Database db;

  /// The file behind [db].
  final String path;

  /// The database file inside [dataDir].
  static File fileIn(Directory dataDir) =>
      File('${dataDir.path}${Platform.pathSeparator}$fileName');

  /// Whether [dataDir] already holds a history.
  static bool existsIn(Directory dataDir) => fileIn(dataDir).existsSync();

  /// Opens the history in [dataDir], creating the data directory, the file and
  /// the schema as needed.
  static MetricDatabase open(Directory dataDir) {
    dataDir.createSync(recursive: true);
    final file = fileIn(dataDir);
    return _open(sqlite3.open(file.path), file.path);
  }

  /// A throwaway history held in memory, for tests.
  static MetricDatabase memory() => _open(sqlite3.openInMemory(), ':memory:');

  static MetricDatabase _open(Database db, String path) {
    try {
      _configure(db);
      _migrate(db);
    } catch (_) {
      db.close();
      rethrow;
    }
    return MetricDatabase._(db, path);
  }

  /// The typed view of this database's `metric_sample` table.
  MetricStore store() => MetricStore(db);

  /// Closes the connection. Every write has already been committed — a
  /// collection is its own transaction — so there is nothing to flush here.
  void close() => db.close();

  static void _configure(Database db) {
    // The collector writes while the charts page reads; the write-ahead log
    // lets the two not wait for each other.
    db.execute('PRAGMA journal_mode = WAL');
    // A sample every few seconds is worth losing the last one of to a power
    // cut, and an fsync per collection would be paid forever.
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA busy_timeout = 3000');
  }

  static void _migrate(Database db) {
    final from = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (from >= schemaVersion) return;
    if (from < 1) _createSampleTable(db);
    db.execute('PRAGMA user_version = $schemaVersion');
  }

  /// The `metric_sample` table — one row per collection. The columns are
  /// spelled out here rather than generated from [MetricField] so that this
  /// file stays readable as a history of what the table has held;
  /// `metric_store_test` fails if the two ever disagree.
  static void _createSampleTable(Database db) {
    db.execute('''
CREATE TABLE metric_sample (
  ts             INTEGER NOT NULL PRIMARY KEY,
  cpu_pct        REAL,
  cpu_temp       REAL,
  cpu_freq_mhz   REAL,
  cpu_power_w    REAL,
  gpu_pct        REAL,
  gpu_temp       REAL,
  gpu_power_w    REAL,
  gpu_mem_mb     REAL,
  mem_pct        REAL,
  mem_used_mb    REAL,
  mem_power_w    REAL,
  disk_pct       REAL,
  disk_read_kbps REAL,
  disk_write_kbps REAL,
  net_down_kbps  REAL,
  net_up_kbps    REAL,
  fan_rpm        REAL
) STRICT
''');
  }
}
