import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'sqlite_transaction.dart';

/// The declared type of a [ConfigEntry]'s value — the `config.value_type`
/// column.
///
/// The column stores text, so every value is written as the text [wire] names
/// and read back through [decode]. Six types cover every setting the app has:
/// a whole number, a fraction, a flag, a string, an arbitrary JSON document,
/// and an enum, which is kept by name rather than by index — reordering a Dart
/// enum must never silently repoint a stored setting.
enum ConfigValueType {
  /// An arbitrary JSON document, kept verbatim.
  json('json'),

  /// A plain string, kept as it is.
  string('string'),

  /// A whole number, in decimal.
  integer('int'),

  /// A fraction, in decimal.
  number('double'),

  /// `1` for true, `0` for false.
  boolean('bool'),

  /// An enum constant's `name`.
  enumeration('enum');

  const ConfigValueType(this.wire);

  /// How this type is spelled in the `value_type` column.
  final String wire;

  /// The type [wire] names, or null when a row carries a spelling this build
  /// does not know.
  static ConfigValueType? fromWire(String wire) {
    for (final type in values) {
      if (type.wire == wire) return type;
    }
    return null;
  }

  /// The text the `value` column holds for [value].
  ///
  /// Throws when [value] is not of this type — a mismatch is a mistake in the
  /// calling code, and it should be loud rather than stored as a surprise.
  String encode(Object? value) => switch (this) {
        ConfigValueType.json => jsonEncode(value),
        ConfigValueType.string => value as String,
        ConfigValueType.integer => '${value as int}',
        ConfigValueType.number => '${(value as num).toDouble()}',
        ConfigValueType.boolean => (value as bool) ? '1' : '0',
        ConfigValueType.enumeration => (value as Enum).name,
      };

  /// What the column text [stored] stands for, or null when it does not hold a
  /// value of this type.
  ///
  /// Nothing throws: a column edited by hand, or written by a different build,
  /// reads as null so the caller falls back to its own default.
  Object? decode(String? stored) {
    if (stored == null) return null;
    return switch (this) {
      ConfigValueType.json => _jsonOrNull(stored),
      ConfigValueType.string => stored,
      ConfigValueType.integer => int.tryParse(stored),
      ConfigValueType.number => double.tryParse(stored),
      ConfigValueType.boolean => switch (stored) {
          '1' || 'true' => true,
          '0' || 'false' => false,
          _ => null,
        },
      ConfigValueType.enumeration => stored,
    };
  }

  static Object? _jsonOrNull(String stored) {
    try {
      return jsonDecode(stored);
    } on FormatException {
      return null;
    }
  }
}

/// One row of the `config` table: a single setting, the type it is stored as,
/// and when it was first written and last changed.
class ConfigEntry {
  const ConfigEntry({
    required this.key,
    required this.name,
    required this.type,
    required this.stored,
    required this.createTime,
    required this.updateTime,
  });

  /// The setting's identity — the table's primary key.
  final String key;

  /// A human label for the setting, for anything that lists the table.
  final String name;

  /// How [stored] is to be read.
  final ConfigValueType type;

  /// The `value` column, verbatim. Null when the row holds no value.
  final String? stored;

  /// When the row was first written, in UTC.
  final DateTime createTime;

  /// When the value last changed, in UTC. A write that changes nothing leaves
  /// this where it was.
  final DateTime updateTime;

  /// [stored] read back as a Dart value.
  Object? get value => type.decode(stored);

  /// The row as it came out of the database.
  static ConfigEntry fromRow(Row row) => ConfigEntry(
        key: row['key'] as String,
        name: row['name'] as String,
        // An unknown spelling is read as text rather than thrown away: the
        // value survives, and only this build's reading of it is guessed.
        type: ConfigValueType.fromWire(row['value_type'] as String) ??
            ConfigValueType.string,
        stored: row['value'] as String?,
        createTime: _time(row['create_time']),
        updateTime: _time(row['update_time']),
      );

  static DateTime _time(Object? millis) =>
      DateTime.fromMillisecondsSinceEpoch(millis as int, isUtc: true);

  @override
  String toString() => 'ConfigEntry($key: ${type.wire} $stored)';
}

/// The `config` table: every persisted setting as one typed row.
///
/// A row is `key name value value_type create_time update_time`, and its
/// `value_type` says how `value` reads — JSON, a string, an int, a double, a
/// bool, or an enum's name. One table therefore holds every kind of setting
/// without a column per type.
///
/// A key that has never been written has no row at all, and that is how an
/// unset setting is told apart from one deliberately set to zero or false:
/// [read] returns null for the first and the value for the second.
class ConfigStore {
  ConfigStore(this._db, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// The table this store reads and writes.
  static const String table = 'config';

  /// The columns, in the order every query in here selects them.
  static const String _columns =
      '"key", name, value, value_type, create_time, update_time';

  final Database _db;
  final DateTime Function() _clock;

  /// The row for [key], or null when it was never written.
  ConfigEntry? entry(String key) {
    final rows =
        _db.select('SELECT $_columns FROM $table WHERE "key" = ?', [key]);
    return rows.isEmpty ? null : ConfigEntry.fromRow(rows.first);
  }

  /// Every row, ordered by key.
  List<ConfigEntry> entries() => _db
      .select('SELECT $_columns FROM $table ORDER BY "key"')
      .map(ConfigEntry.fromRow)
      .toList(growable: false);

  /// Whether [key] has a row.
  bool has(String key) => entry(key) != null;

  /// Writes [value] under [key] as [type], and returns the stored row.
  ///
  /// A key that is already there keeps its `create_time`; its `update_time`
  /// moves only when this write actually changes something, so flushing a
  /// whole settings object does not rewrite the history of every row it
  /// happens to touch.
  ConfigEntry put(
    String key,
    String name,
    ConfigValueType type,
    Object? value,
  ) {
    final now = _clock().toUtc().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO $table ("key", name, value, value_type, create_time, update_time) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT("key") DO UPDATE SET '
      'name = excluded.name, '
      'value = excluded.value, '
      'value_type = excluded.value_type, '
      'update_time = excluded.update_time '
      'WHERE $table.value IS NOT excluded.value '
      'OR $table.value_type IS NOT excluded.value_type '
      'OR $table.name IS NOT excluded.name',
      [key, name, type.encode(value), type.wire, now, now],
    );
    return entry(key)!;
  }

  /// Drops [key]. True when there was a row to drop.
  bool remove(String key) {
    _db.execute('DELETE FROM $table WHERE "key" = ?', [key]);
    return _db.updatedRows > 0;
  }

  /// The value stored under [key], read as [type] declares, or null when the
  /// row is absent, declares a different type, or holds nothing this build can
  /// read.
  Object? read(String key, ConfigValueType type) {
    final row = entry(key);
    if (row == null || row.type != type) return null;
    return row.value;
  }

  /// The constant of [values] whose `name` is stored under [key], or null when
  /// the row is absent or names a constant this build does not have.
  E? enumOf<E extends Enum>(String key, List<E> values) {
    final stored = read(key, ConfigValueType.enumeration) as String?;
    if (stored == null) return null;
    for (final value in values) {
      if (value.name == stored) return value;
    }
    return null;
  }

  /// Runs [body] inside one transaction, so a group of settings lands together
  /// or not at all.
  ///
  /// Not re-entrant: it is the outermost writer's tool.
  void writeAll(void Function() body) => _db.transaction(body);
}
