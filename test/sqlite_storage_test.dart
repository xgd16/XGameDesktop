import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/data/app_database.dart';
import 'package:xgame_desktop/data/config_store.dart';
import 'package:xgame_desktop/state/app_power.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/state/settings_spec.dart';

/// Settings as they are actually stored: the profile database, the `config`
/// table, and the one-time move off `settings.json`.
void main() {
  late Directory dataDir;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_sqlite');
    // The low-power verdict is process-global; nothing here may inherit it.
    addTearDown(() => AppPower.economy.value = false);
  });

  tearDown(() {
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {
      // An open connection can hold the file; the temp folder is a scratch pad.
    }
  });

  File legacyFile() => File('${dataDir.path}\\settings.json');

  /// Runs [body] over the profile's `config` table and closes up after.
  void withTable(void Function(ConfigStore config) body) {
    final db = AppDatabase.open(dataDir);
    try {
      body(db.configStore());
    } finally {
      db.close();
    }
  }

  test('第一次启动把旧的 settings.json 读进 config 表，之后只认表', () async {
    legacyFile().writeAsStringSync(jsonEncode({
      'palette': 3, // 旧文件存的是下标
      'immersive': true,
      'launchOnStartup': true,
      'taskbarBlend': false,
      'usageMode': 1,
      'sceneFps': 60,
      'lowPower': true,
      'background': null,
      'kind': 'image',
      'source': null,
      'dim': 0.35,
      'blur': 9,
      'fit': 2,
      'weSource': false,
      'weId': null,
      'weLabel': 'Into The Woods · 场景',
    }));

    final upgraded = SettingsProvider(dataDir: dataDir);
    await upgraded.load();
    expect(upgraded.palette, PaletteId.lava);
    expect(upgraded.immersiveOnLaunch, isTrue);
    expect(upgraded.launchOnStartup, isTrue);
    expect(upgraded.immersiveTaskbarBlend, isFalse);
    expect(upgraded.usageSensorMode, 1);
    expect(upgraded.sceneFps, 60);
    expect(upgraded.lowPower, isTrue);
    expect(upgraded.backgroundDim, 0.35);
    expect(upgraded.backgroundBlur, 9);
    expect(upgraded.backgroundFit, BackgroundFit.tile);
    expect(upgraded.backgroundLabel, 'Into The Woods · 场景');
    expect(upgraded.hasBackground, isFalse, reason: '旧文件没留图片副本');
    upgraded.dispose();

    // 表已经在，旧文件从此只是历史：之后放进去什么都不再读。
    legacyFile().writeAsStringSync(jsonEncode({'palette': 1, 'sceneFps': 15}));

    final again = SettingsProvider(dataDir: dataDir);
    await again.load();
    expect(again.palette, PaletteId.lava);
    expect(again.sceneFps, 60);
    expect(again.backgroundDim, 0.35);
    again.dispose();
  });

  test('枚举在表里存的是名字，不是下标', () async {
    legacyFile()
        .writeAsStringSync(jsonEncode({'palette': 3, 'fit': 2, 'kind': 'video'}));

    final settings = SettingsProvider(dataDir: dataDir);
    await settings.load();
    settings.dispose();

    withTable((config) {
      expect(config.entry(Settings.palette.key)!.type,
          ConfigValueType.enumeration);
      expect(config.entry(Settings.palette.key)!.stored, 'lava',
          reason: '重排 PaletteId 不该把已存的设置指到别的颜色上');
      expect(config.entry(Settings.backgroundFit.key)!.stored, 'tile');
      expect(config.entry(Settings.backgroundKind.key)!.stored, 'video');
    });
  });

  test('旧文件里越界的、类型不对的、缺的值各回各的默认', () async {
    legacyFile().writeAsStringSync(jsonEncode({
      'palette': 99, // 没有这个下标
      'sceneFps': 'fast', // 不是整数
      'fit': -1, // 越界
      'dim': 5.0, // 超出允许范围
    }));

    final settings = SettingsProvider(dataDir: dataDir);
    await settings.load();
    expect(settings.palette, PaletteId.violet);
    expect(settings.sceneFps, 30);
    expect(settings.backgroundFit, BackgroundFit.cover);
    expect(settings.backgroundDim, 0.9, reason: '导入的值照旧要夹到上限内');
    settings.dispose();
  });

  test('旧文件坏掉或根本没有，照常起来用默认值', () async {
    final fresh = SettingsProvider(dataDir: dataDir);
    await fresh.load();
    expect(fresh.palette, PaletteId.violet);
    expect(fresh.sceneFps, 30);
    fresh.dispose();

    legacyFile().writeAsStringSync('{ 这不是 JSON');
    final broken = SettingsProvider(dataDir: dataDir);
    await broken.load();
    expect(broken.palette, PaletteId.violet);
    expect(broken.sceneFps, 30);
    broken.dispose();
  });

  test('低功耗档的第三个值就是没有这一行', () async {
    final chosen = SettingsProvider(dataDir: dataDir)..setLowPower(true);
    chosen.dispose();
    withTable((config) {
      expect(config.entry(Settings.lowPower.key)!.stored, '1');
    });

    // 交回给电池：行没有了，而不是变成一行 false。
    final auto = SettingsProvider(dataDir: dataDir);
    await auto.load();
    expect(auto.lowPower, isTrue);
    auto.setLowPower(null);
    auto.dispose();

    withTable((config) {
      expect(config.has(Settings.lowPower.key), isFalse,
          reason: '"没选过" 是没有行，不是一行假值');
    });

    final back = SettingsProvider(dataDir: dataDir);
    await back.load();
    expect(back.lowPower, isNull);
    expect(back.lowPowerOn, isFalse);
    back.dispose();
  });

  test('落库的行都在目录里：键、类型、名字三者对得上', () async {
    final settings = SettingsProvider(dataDir: dataDir)
      ..setSceneFps(60)
      ..setImmersiveOnLaunch(true);
    settings.dispose();

    final byKey = {for (final spec in Settings.all) spec.key: spec};
    withTable((config) {
      final rows = config.entries();
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final spec = byKey[row.key];
        expect(spec, isNotNull, reason: '${row.key} 不在设置目录里');
        expect(row.type, spec!.type, reason: '${row.key} 的类型和目录不一致');
        expect(row.name, spec.name, reason: '${row.key} 的名字和目录不一致');
      }
    });
  });

  test('没选过的设置就是表里没有这一行', () async {
    final settings = SettingsProvider(dataDir: dataDir)
      ..setSceneFps(60)
      ..setImmersiveOnLaunch(true);
    settings.dispose();

    withTable((config) {
      expect(config.has(Settings.lowPower.key), isFalse);
      expect(config.has(Settings.backgroundImage.key), isFalse);
      expect(config.has(Settings.backgroundWeLabel.key), isFalse);
      expect(config.entry(Settings.sceneFps.key)!.stored, '60');
    });
  });
}
