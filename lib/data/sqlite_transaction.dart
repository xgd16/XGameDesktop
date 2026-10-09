import 'package:sqlite3/sqlite3.dart';

/// Runs [body] as one transaction: everything it writes lands, or none of it
/// does.
///
/// Not re-entrant — it is the outermost writer's tool. A store that groups a
/// batch of writes uses it; the flag bookkeeping in `app_meta` does not need
/// to, because a one-time import writes absolute values rather than adding to
/// what is already there.
extension SqliteTransaction on Database {
  void transaction(void Function() body) {
    execute('BEGIN');
    try {
      body();
      execute('COMMIT');
    } catch (_) {
      execute('ROLLBACK');
      rethrow;
    }
  }
}
