import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/data/app_database.dart';
import 'package:xgame_desktop/data/config_store.dart';

/// The `config` table itself: one typed row per setting, and the six
/// `value_type`s it has to carry.
void main() {
  late AppDatabase database;

  setUp(() => database = AppDatabase.memory());
  tearDown(() => database.close());

  ConfigStore store({DateTime Function()? clock}) =>
      database.configStore(clock: clock);

  test('config 表就是要求的六列，key 是主键', () {
    final columns = database.db.select('PRAGMA table_info(config)');
    expect(columns.map((row) => row['name']).toList(), [
      'key',
      'name',
      'value',
      'value_type',
      'create_time',
      'update_time',
    ]);
    expect(columns.first['pk'], 1, reason: 'key 是主键');
    expect(columns.firstWhere((row) => row['name'] == 'value_type')['notnull'],
        1,
        reason: '每行都要说明 value 怎么读');
  });

  test('六种 value_type 各存各读，value 列里的文本就是类型的样子', () {
    final config = store();

    config.put('t.json', 'JSON', ConfigValueType.json, {
      'a': [1, 2],
      'b': true,
    });
    config.put('t.string', '文本', ConfigValueType.string, 'ping');
    config.put('t.int', '整数', ConfigValueType.integer, 42);
    config.put('t.double', '小数', ConfigValueType.number, 0.35);
    config.put('t.bool', '布尔', ConfigValueType.boolean, true);
    config.put('t.enum', '枚举', ConfigValueType.enumeration, PaletteId.lava);

    expect(config.read('t.json', ConfigValueType.json), {
      'a': [1, 2],
      'b': true,
    });
    expect(config.read('t.string', ConfigValueType.string), 'ping');
    expect(config.read('t.int', ConfigValueType.integer), 42);
    expect(config.read('t.double', ConfigValueType.number), 0.35);
    expect(config.read('t.bool', ConfigValueType.boolean), isTrue);
    expect(config.enumOf('t.enum', PaletteId.values), PaletteId.lava);

    expect(config.entry('t.json')!.stored, '{"a":[1,2],"b":true}');
    expect(config.entry('t.string')!.stored, 'ping');
    expect(config.entry('t.int')!.stored, '42');
    expect(config.entry('t.double')!.stored, '0.35');
    expect(config.entry('t.bool')!.stored, '1');
    expect(config.entry('t.enum')!.stored, 'lava',
        reason: '枚举存名字，不存下标');
    expect(config.entry('t.int')!.type, ConfigValueType.integer);
    expect(config.entry('t.int')!.name, '整数');
  });

  test('没写过的 key 和写成零值的 key 分得开', () {
    final config = store()
      ..put('zero', '零', ConfigValueType.integer, 0)
      ..put('off', '假', ConfigValueType.boolean, false)
      ..put('blank', '空串', ConfigValueType.string, '');

    expect(config.has('never'), isFalse);
    expect(config.read('never', ConfigValueType.integer), isNull);
    expect(config.read('zero', ConfigValueType.integer), 0);
    expect(config.read('off', ConfigValueType.boolean), isFalse);
    expect(config.read('blank', ConfigValueType.string), '');
  });

  test('value_type 对不上、值被改坏、枚举名不认识，都读作未设置', () {
    final config = store()
      ..put('n', '整数', ConfigValueType.integer, 7)
      ..put('p', '枚举', ConfigValueType.enumeration, PaletteId.violet);

    // 读取方要的类型和行里声明的不是一回事：不猜。
    expect(config.read('n', ConfigValueType.string), isNull);

    database.db.execute(
        'UPDATE config SET value = ? WHERE "key" = ?', ['not a number', 'n']);
    expect(config.read('n', ConfigValueType.integer), isNull);

    // 一个别的版本写下的枚举名，本版本没有这个常量。
    database.db.execute('UPDATE config SET value = ? WHERE "key" = ?',
        ['chartreuse', 'p']);
    expect(config.enumOf('p', PaletteId.values), isNull);
  });

  test('value_type 认不出来时按文本读，值本身不丢', () {
    final config = store();
    database.db.execute(
        'INSERT INTO config ("key", name, value, value_type, create_time, update_time) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        ['odd', '怪类型', 'kept', 'decimal', 0, 0]);

    final entry = config.entry('odd')!;
    expect(entry.type, ConfigValueType.string);
    expect(entry.value, 'kept');
  });

  test('create_time 只在第一次写入时定，update_time 只在值真的变了才动', () {
    var now = DateTime.utc(2026, 1, 1, 12);
    final config = store(clock: () => now);

    final first = config.put('a', 'A', ConfigValueType.integer, 1);
    expect(first.createTime, DateTime.utc(2026, 1, 1, 12));
    expect(first.updateTime, first.createTime);

    now = DateTime.utc(2026, 1, 2);
    final second = config.put('a', 'A', ConfigValueType.integer, 2);
    expect(second.createTime, DateTime.utc(2026, 1, 1, 12),
        reason: '第一次写入的时间要留着');
    expect(second.updateTime, DateTime.utc(2026, 1, 2));

    now = DateTime.utc(2026, 1, 3);
    final third = config.put('a', 'A', ConfigValueType.integer, 2);
    expect(third.updateTime, DateTime.utc(2026, 1, 2),
        reason: '整个设置对象重刷一遍，没变的行不该被写上新时间');
  });

  test('remove 删行，entries 按 key 排序', () {
    final config = store()
      ..put('b', 'B', ConfigValueType.boolean, true)
      ..put('a', 'A', ConfigValueType.string, 'x')
      ..put('c', 'C', ConfigValueType.integer, 1);

    expect(config.entries().map((entry) => entry.key).toList(),
        ['a', 'b', 'c']);

    expect(config.remove('b'), isTrue);
    expect(config.remove('b'), isFalse, reason: '第二次没有行可删');
    expect(config.has('b'), isFalse);
  });

  test('writeAll 里的异常让这一批一条都不落库', () {
    final config = store();

    expect(
      () => config.writeAll(() {
        config.put('kept', 'K', ConfigValueType.integer, 1);
        throw StateError('boom');
      }),
      throwsStateError,
    );

    expect(config.has('kept'), isFalse);
  });
}
