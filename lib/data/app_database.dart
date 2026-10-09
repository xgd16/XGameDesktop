import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'app_activity_store.dart';
import 'config_store.dart';

/// The profile database: one file inside the data directory, opened once and
/// kept open for the life of the process.
///
/// The schema is created on the first open and versioned through SQLite's own
/// `user_version`, so a later release can add tables without having to guess
/// what an older file holds. Bookkeeping that is not the schema — whether a
/// pre-SQLite file has already been imported — lives in `app_meta` (see
/// [once]).
class AppDatabase {
  AppDatabase._(this.db, this.path);

  /// The file a profile's settings and activity live in.
  static const String fileName = 'xgame.db';

  /// What `user_version` reads once the schema below is in place. A new table
  /// gets a new number and a step in [_migrate].
  ///
  /// 1. the `config` table
  /// 2. `app_usage`, `app_pin` and `app_meta`
  static const int schemaVersion = 2;

  /// The one-time flags the pre-SQLite files are imported under. A profile that
  /// has run an import records it in `app_meta`, and no later launch — nor a
  /// "clear the statistics" — can make it run again.
  static const String settingsImportFlag = 'legacy.settings_json';
  static const String activityImportFlag = 'legacy.app_activity';

  /// The open connection. Callers hand this to a store and leave it alone.
  final Database db;

  /// The file behind [db].
  final String path;

  /// The database file inside [dataDir].
  static File fileIn(Directory dataDir) =>
      File('${dataDir.path}${Platform.pathSeparator}$fileName');

  /// Whether [dataDir] already holds a database.
  static bool existsIn(Directory dataDir) => fileIn(dataDir).existsSync();

  /// Opens the database in [dataDir], creating the data directory, the file and
  /// the schema as needed.
  static AppDatabase open(Directory dataDir) {
    dataDir.createSync(recursive: true);
    final file = fileIn(dataDir);
    return _open(sqlite3.open(file.path), file.path);
  }

  /// A throwaway database held in memory, for tests that exercise a store
  /// without a profile directory.
  static AppDatabase memory() => _open(sqlite3.openInMemory(), ':memory:');

  static AppDatabase _open(Database db, String path) {
    try {
      _configure(db);
      _migrate(db);
    } catch (_) {
      db.close();
      rethrow;
    }
    return AppDatabase._(db, path);
  }

  /// The typed view of this database's `config` table — see [ConfigStore].
  ///
  /// [clock] is the store's source of `create_time`/`update_time`; the default
  /// is the wall clock.
  ConfigStore configStore({DateTime Function()? clock}) =>
      ConfigStore(db, clock: clock);

  /// The per-app activity tables — see [AppActivityStore].
  AppActivityStore activityStore({DateTime Function()? clock}) =>
      AppActivityStore(db, clock: clock);

  /// Whether the one-time step recorded under [flag] has already run for this
  /// profile.
  bool hasFlag(String flag) =>
      db.select('SELECT value FROM app_meta WHERE "key" = ?', [flag]).isNotEmpty;

  /// Records that the one-time step under [flag] has run.
  void setFlag(String flag) => db.execute(
        'INSERT INTO app_meta ("key", value) VALUES (?, ?) '
        'ON CONFLICT("key") DO UPDATE SET value = excluded.value',
        [flag, '1'],
      );

  /// Runs [body] the first time this profile is asked for [flag], and never
  /// again. Returns whether it ran.
  ///
  /// The flag is written only after [body] returns, so an import that threw
  /// halfway is tried again on the next launch rather than leaving the profile
  /// silently half-migrated. Importers must therefore be safe to run twice —
  /// they write absolute values rather than adding to what is there.
  bool once(String flag, void Function() body) {
    if (hasFlag(flag)) return false;
    body();
    setFlag(flag);
    return true;
  }

  /// Closes the connection. Every write has already been committed — a store
  /// write is its own transaction — so there is nothing to flush here.
  void close() => db.close();

  static void _configure(Database db) {
    // The write-ahead log lets a reader look at the settings while something
    // else writes one, and a write here is a handful of rows.
    db.execute('PRAGMA journal_mode = WAL');
    // This lives on the user's own disk: an fsync per launch buys little, and
    // losing the very last write to a power cut costs little.
    db.execute('PRAGMA synchronous = NORMAL');
    // A second connection — a second instance, or a tool — waits for the writer
    // instead of failing outright.
    db.execute('PRAGMA busy_timeout = 3000');
    db.execute('PRAGMA foreign_keys = ON');
  }

  static void _migrate(Database db) {
    final from = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (from >= schemaVersion) return;
    if (from < 1) _createConfigTable(db);
    if (from < 2) _createActivityTables(db);
    // A version-1 profile already stored its settings in `config`: the import
    // off `settings.json` ran when that file was created, before there was a
    // flag to record it. Say so now, or this upgrade would pour the old file
    // back over every setting the user has changed since.
    if (from == 1) _writeFlag(db, settingsImportFlag);
    db.execute('PRAGMA user_version = $schemaVersion');
  }

  /// The `config` table — see [ConfigStore] for what reads and writes it.
  static void _createConfigTable(Database db) {
    db.execute('''
CREATE TABLE config (
  "key"       TEXT    NOT NULL PRIMARY KEY,
  name        TEXT    NOT NULL DEFAULT '',
  value       TEXT,
  value_type  TEXT    NOT NULL,
  create_time INTEGER NOT NULL,
  update_time INTEGER NOT NULL
) STRICT
''');
  }

  /// The per-app tables, and the bookkeeping table the one-time imports use.
  static void _createActivityTables(Database db) {
    // One row per app ever launched. `name` is kept here rather than looked up,
    // so an app that has since been uninstalled still reads as something in the
    // statistics. The two timestamps are nullable: the launch counts imported
    // from `usage.json` never knew when they happened.
    db.execute('''
CREATE TABLE app_usage (
  app_key      TEXT    NOT NULL PRIMARY KEY,
  name         TEXT    NOT NULL DEFAULT '',
  launches     INTEGER NOT NULL DEFAULT 0,
  first_launch INTEGER,
  last_launch  INTEGER,
  create_time  INTEGER NOT NULL,
  update_time  INTEGER NOT NULL
) STRICT
''');
    // `position` is what makes the pinned row an order rather than a set — the
    // arrangement the user made with the pad's left/right.
    db.execute('''
CREATE TABLE app_pin (
  app_key     TEXT    NOT NULL PRIMARY KEY,
  position    INTEGER NOT NULL,
  create_time INTEGER NOT NULL,
  update_time INTEGER NOT NULL
) STRICT
''');
    // Not settings: this is the database's own notebook — which one-time steps
    // have run. Kept apart from `config` so that table stays exactly what its
    // name says it is.
    db.execute('''
CREATE TABLE app_meta (
  "key" TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
) STRICT
''');
  }

  static void _writeFlag(Database db, String flag) => db.execute(
        'INSERT INTO app_meta ("key", value) VALUES (?, ?) '
        'ON CONFLICT("key") DO UPDATE SET value = excluded.value',
        [flag, '1'],
      );
}
