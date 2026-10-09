import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xgame_desktop/data/app_activity_store.dart';
import 'package:xgame_desktop/data/app_database.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/state/apps_provider.dart';
import 'package:xgame_desktop/state/legacy_app_import.dart';
import 'package:xgame_desktop/state/settings_spec.dart';

/// `app_usage` and `app_pin`, the one-time move off `usage.json` / `pins.json`,
/// and the profile upgrade that adds both.
void main() {
  const steamKey = r'c:\start menu\steam.lnk';
  const zcodeKey = r'c:\start menu\zcode.lnk';

  group('app_usage：启动次数与时间', () {
    late AppDatabase database;
    late AppActivityStore store;
    var now = DateTime.utc(2026, 3, 1, 9);

    setUp(() {
      now = DateTime.utc(2026, 3, 1, 9);
      database = AppDatabase.memory();
      store = database.activityStore(clock: () => now);
    });
    tearDown(() => database.close());

    test('第一次启动开一行，之后只加次数、动最后时间', () {
      final first = store.countLaunch(steamKey, 'Steam');
      expect(first.launches, 1);
      expect(first.name, 'Steam');
      expect(first.firstLaunch, DateTime.utc(2026, 3, 1, 9));
      expect(first.lastLaunch, first.firstLaunch);
      expect(first.createTime, first.firstLaunch);

      now = DateTime.utc(2026, 3, 2, 20);
      final second = store.countLaunch(steamKey, 'Steam');
      expect(second.launches, 2);
      expect(second.firstLaunch, DateTime.utc(2026, 3, 1, 9),
          reason: '首次启动时间要留着');
      expect(second.lastLaunch, DateTime.utc(2026, 3, 2, 20));
      expect(second.createTime, DateTime.utc(2026, 3, 1, 9));
      expect(store.totalLaunches, 2);
      expect(store.trackedApps, 1);
    });

    test('空名字不会把已经记住的应用名抹掉', () {
      store.countLaunch(steamKey, 'Steam');
      expect(store.countLaunch(steamKey, '').name, 'Steam');
    });

    test('按次数排序，同次数按名字', () {
      store
        ..countLaunch('b', 'Beta')
        ..countLaunch('b', 'Beta')
        ..countLaunch('a', 'Alpha')
        ..countLaunch('a', 'Alpha')
        ..countLaunch('c', 'Gamma');

      expect(store.launches().map((row) => row.name).toList(),
          ['Alpha', 'Beta', 'Gamma']);
      expect(store.launches().first.launches, 2);
    });

    test('putLaunch 是绝对写入：导入重跑不会把次数翻倍', () {
      store.putLaunch(steamKey, name: 'Steam', launches: 5);
      store.putLaunch(steamKey, name: 'Steam', launches: 5);
      expect(store.launch(steamKey)!.launches, 5);
    });

    test('没有名字时从路径里取一个能读的', () {
      expect(store.putLaunch(steamKey, name: '', launches: 1).displayName,
          'steam');
      expect(
          store
              .putLaunch('steam://rungameid/4000', name: '', launches: 1)
              .displayName,
          '4000');
      expect(store.putLaunch('x', name: 'WeGame', launches: 1).displayName,
          'WeGame');
    });

    test('清空统计只删启动记录，固定项留着', () {
      store
        ..countLaunch(steamKey, 'Steam')
        ..setPins([steamKey]);

      expect(store.clearLaunches(), 1);
      expect(store.launches(), isEmpty);
      expect(store.totalLaunches, 0);
      expect(store.trackedApps, 0);
      expect(store.pinned(), [steamKey], reason: '钉选是排布，不是统计');
    });
  });

  group('app_pin：顺序', () {
    late AppDatabase database;
    late AppActivityStore store;

    setUp(() {
      database = AppDatabase.memory();
      store = database.activityStore();
    });
    tearDown(() => database.close());

    test('setPins 把表对齐到列表：顺序、增删都跟着走', () {
      store.setPins(['a', 'b', 'c']);
      expect(store.pinned(), ['a', 'b', 'c']);

      store.setPins(['c', 'a']);
      expect(store.pinned(), ['c', 'a'], reason: '顺序就是列表的顺序');

      store.setPins([]);
      expect(store.pinned(), isEmpty);
    });

    test('没动过位置的行不重写 update_time', () {
      var now = DateTime.utc(2026, 5, 1);
      final clocked = database.activityStore(clock: () => now);
      clocked.setPins(['a', 'b']);
      final before = database.db
          .select('SELECT update_time FROM app_pin WHERE app_key = ?', ['a'])
          .first['update_time'] as int;

      now = DateTime.utc(2026, 5, 2);
      clocked.setPins(['a', 'b', 'c']);
      final after = database.db
          .select('SELECT update_time FROM app_pin WHERE app_key = ?', ['a'])
          .first['update_time'] as int;
      expect(after, before);
    });
  });

  group('一次性的导入标记', () {
    late AppDatabase database;
    setUp(() => database = AppDatabase.memory());
    tearDown(() => database.close());

    test('once 只跑一次', () {
      var runs = 0;
      expect(database.once('legacy.x', () => runs++), isTrue);
      expect(database.once('legacy.x', () => runs++), isFalse);
      expect(runs, 1);
      expect(database.hasFlag('legacy.x'), isTrue);
    });

    test('半路失败的导入下次还会再试', () {
      expect(
        () => database.once('legacy.y', () => throw StateError('boom')),
        throwsStateError,
      );
      expect(database.hasFlag('legacy.y'), isFalse);

      var runs = 0;
      expect(database.once('legacy.y', () => runs++), isTrue);
      expect(runs, 1);
    });
  });

  group('旧的 usage.json / pins.json', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('xg_activity'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('导入次数与固定顺序，键统一成小写', () {
      File('${dir.path}\\usage.json').writeAsStringSync(jsonEncode({
        steamKey: 3,
        zcodeKey: 1,
        r'c:\a\gone.lnk': 0, // 零点几次不算记录
      }));
      File('${dir.path}\\pins.json')
          .writeAsStringSync(jsonEncode([r'C:\Start Menu\ZCode.lnk']));

      final db = AppDatabase.open(dir);
      final store = db.activityStore();
      importLegacyAppActivity(store, dir);

      expect(store.totalLaunches, 4);
      expect(store.launch(r'c:\a\gone.lnk'), isNull);
      final steam = store.launch(steamKey)!;
      expect(steam.launches, 3);
      expect(steam.lastLaunch, isNull, reason: '旧文件没有时间，编不出来');
      expect(steam.displayName, 'steam');
      expect(store.pinned(), [zcodeKey]);
      db.close();
    });

    test('重跑不会把次数加一倍', () {
      File('${dir.path}\\usage.json')
          .writeAsStringSync(jsonEncode({steamKey: 3}));
      final db = AppDatabase.open(dir);
      final store = db.activityStore();
      importLegacyAppActivity(store, dir);
      importLegacyAppActivity(store, dir);
      expect(store.launch(steamKey)!.launches, 3);
      db.close();
    });

    test('没有旧文件、或者旧文件坏掉，都静静地什么都不做', () {
      final db = AppDatabase.open(dir);
      final store = db.activityStore();
      importLegacyAppActivity(store, dir);
      expect(store.launches(), isEmpty);

      File('${dir.path}\\usage.json').writeAsStringSync('{ 这不是 JSON');
      importLegacyAppActivity(store, dir);
      expect(store.launches(), isEmpty);
      db.close();
    });
  });

  group('数据库升级到 v2', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('xg_upgrade'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// Writes the database a version-1 build left behind: the `config` table
    /// and nothing else.
    void writeV1Profile() {
      final db = sqlite3.open(AppDatabase.fileIn(dir).path);
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
      db.execute(
        'INSERT INTO config ("key", name, value, value_type, create_time, update_time) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        ['appearance.palette', '主题颜色', 'lava', 'enum', 0, 0],
      );
      db.execute('PRAGMA user_version = 1');
      db.close();
    }

    test('v1 的库升上来会补上"设置已导入"的标记，旧文件不再倒一遍', () {
      writeV1Profile();
      // 用户的旧文件还躺在旁边；它记的是升级之前的状态。
      File('${dir.path}\\settings.json')
          .writeAsStringSync(jsonEncode({'palette': 1, 'sceneFps': 60}));

      final upgraded = AppDatabase.open(dir);
      expect(upgraded.hasFlag(AppDatabase.settingsImportFlag), isTrue,
          reason: 'v1 的库本来就是导入来的，升级不能让它再导一次');

      final config = upgraded.configStore();
      expect(config.valueOf(Settings.palette), 'lava',
          reason: '库里那条才是用户现在的设置');
      expect(config.has(Settings.sceneFps.key), isFalse);

      // 新表都在，而且是空的。
      expect(upgraded.activityStore().launches(), isEmpty);
      expect(upgraded.activityStore().pinned(), isEmpty);
      expect(upgraded.hasFlag(AppDatabase.activityImportFlag), isFalse,
          reason: '活动表的导入还没跑过');
      upgraded.close();
    });

    test('全新的库没有任何标记，两个导入都会跑', () {
      final fresh = AppDatabase.open(dir);
      expect(fresh.hasFlag(AppDatabase.settingsImportFlag), isFalse);
      expect(fresh.hasFlag(AppDatabase.activityImportFlag), isFalse);
      expect(fresh.db.select('SELECT name FROM sqlite_master WHERE type = '
          "'table' ORDER BY name").map((r) => r['name']).toList(), [
        'app_meta',
        'app_pin',
        'app_usage',
        'config',
      ]);
      fresh.close();
    });
  });

  group('AppsProvider 与两张表', () {
    late Directory dataDir;
    setUp(() => dataDir = Directory.systemTemp.createTempSync('xg_apps'));
    tearDown(() {
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// A provider that reads the profile but manufactures its own catalog.
    AppsProvider providerWith(List<AppEntry> catalog) {
      final provider = AppsProvider(
        dataDir: dataDir,
        launcher: (_) => true,
        scanner: () async => catalog,
      );
      addTearDown(provider.dispose);
      return provider;
    }

    test('启动次数与固定项落在表里，换个实例读得回来', () async {
      final steam = AppEntry(name: 'Steam', path: r'C:\Start Menu\Steam.lnk');
      final zcode = AppEntry(name: 'ZCode', path: r'C:\Start Menu\ZCode.lnk');

      final first = providerWith([steam, zcode]);
      await first.load();
      first.launch(steam);
      first.launch(steam);
      first.launch(zcode);
      first.pin(zcode);
      expect(first.totalLaunches, 3);
      first.dispose();

      final second = providerWith([steam, zcode]);
      await second.load();
      expect(second.launchCount(steam), 2);
      expect(second.launchCount(zcode), 1);
      expect(second.totalLaunches, 3);
      expect(second.isPinned(zcode), isTrue);
      expect(second.isPinned(steam), isFalse);
      expect(second.launchHistory.first.displayName, 'Steam',
          reason: '次数最多的排最前');
      expect(second.launchHistory.first.lastLaunch, isNotNull);
    });

    test('清空统计把表也清了，重开还是空的', () async {
      final steam = AppEntry(name: 'Steam', path: r'C:\Start Menu\Steam.lnk');
      final first = providerWith([steam]);
      await first.load();
      first.launch(steam);
      first.clearLaunchStats();
      expect(first.totalLaunches, 0);
      first.dispose();

      final second = providerWith([steam]);
      await second.load();
      expect(second.totalLaunches, 0);
      expect(second.launchHistory, isEmpty);
    });

    test('卸掉的应用仍留在统计里，名字回落到路径', () async {
      final gone = AppEntry(name: 'WeGame', path: r'C:\Start Menu\WeGame.lnk');
      final first = providerWith([gone]);
      await first.load();
      first.launch(gone);
      first.dispose();

      // 下一次扫描已经没有它了。
      final second = providerWith([]);
      await second.load();
      final row = second.launchHistory.single;
      expect(row.name, 'WeGame', reason: '表里记着名字');
      expect(row.displayName, 'WeGame');
      expect(second.catalogEntry(row.key), isNull, reason: '目录里已经没有了');
    });

    test('旧文件导进来的次数没名字，扫描一次就把名字补上', () async {
      final steam = AppEntry(name: 'Steam', path: r'C:\Start Menu\Steam.lnk');
      File('${dataDir.path}\\usage.json').writeAsStringSync(
          jsonEncode({r'c:\start menu\steam.lnk': 4, r'c:\gone\tool.lnk': 2}));

      final apps = providerWith([steam]);
      await apps.load();

      // 目录里还有的那个拿到真名，卸载掉的那个保持无名、从路径读。
      expect(apps.launchHistory.map((row) => row.displayName).toSet(),
          {'Steam', 'tool'});
      expect(apps.launchCount(steam), 4);
      apps.dispose();

      // 名字是写回表里的，不是只在内存里补的。
      final db = AppDatabase.open(dataDir);
      expect(db.activityStore().launch(r'c:\start menu\steam.lnk')!.name, 'Steam');
      expect(db.activityStore().launch(r'c:\gone\tool.lnk')!.name, isEmpty);
      db.close();
    });
  });
}
