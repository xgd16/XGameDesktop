import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/native/steam_games.dart';

/// The scan reads whatever [roots] hands it, so every test builds its own
/// little Steam tree: manifests in `steamapps`, art in `appcache\librarycache`.
void main() {
  late Directory library;

  setUp(() {
    library = Directory.systemTemp.createTempSync('steam_games_test');
  });

  tearDown(() {
    try {
      library.deleteSync(recursive: true);
    } catch (_) {}
  });

  void manifest(int appId, String name, {String flags = '4'}) {
    final dir = Directory('${library.path}\\steamapps')
      ..createSync(recursive: true);
    File('${dir.path}\\appmanifest_$appId.acf').writeAsStringSync('''
"AppState"
{
	"appid"		"$appId"
	"Universe"		"1"
	"name"		"$name"
	"StateFlags"		"$flags"
	"installdir"		"Game$appId"
	"LastUpdated"		"1700000000"
}
''');
  }

  String cover(int appId, String name) {
    final dir = Directory('${library.path}\\appcache\\librarycache\\$appId')
      ..createSync(recursive: true);
    final file = File('${dir.path}\\$name')..writeAsBytesSync([1, 2, 3]);
    return file.path;
  }

  test('解析已安装的游戏，跳过运行库、未装完的和 Wallpaper Engine', () {
    manifest(4000, 'Project Zomboid');
    manifest(228983, 'Steamworks Common Redistributables');
    manifest(431960, 'Wallpaper Engine：壁纸引擎');
    manifest(1245620, 'Stardew Valley', flags: '2'); // 更新中，不可启动
    manifest(1517290, 'Proton Hotfix');
    manifest(1391110, 'Steam Linux Runtime 3.0 (SNR)');
    manifest(0, 'Broken Manifest');

    final games = SteamGames.scan(roots: [library.path]);

    expect(games.map((g) => g.name), ['Project Zomboid']);
    final game = games.single;
    expect(game.path, 'steam://rungameid/4000');
    expect(game.isGame, isTrue);
    expect(game.category, AppCategory.game);
    expect(game.hasDesktop, isFalse);
    expect(game.iconFile, isNull);
  });

  test('同一游戏挂在多个库只收一次，结果按名字排序', () {
    manifest(4000, 'Zomboid');
    final other = Directory.systemTemp.createTempSync('steam_games_other');
    addTearDown(() => other.deleteSync(recursive: true));
    final otherLib = other.path;
    Directory('$otherLib\\steamapps').createSync(recursive: true);
    File('$otherLib\\steamapps\\appmanifest_105600.acf').writeAsStringSync(
        '"AppState"\n{\n\t"appid"\t\t"105600"\n\t"name"\t\t"Terraria"\n'
        '\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"Terraria"\n}\n');
    // 两个库都写着 4000：装机盘和备份库常见的情况。
    File('$otherLib\\steamapps\\appmanifest_4000.acf').writeAsStringSync(
        '"AppState"\n{\n\t"appid"\t\t"4000"\n\t"name"\t\t"Zomboid"\n'
        '\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"Zomboid"\n}\n');

    final games = SteamGames.scan(roots: [library.path, otherLib]);

    expect(games.map((g) => g.name), ['Terraria', 'Zomboid']);
  });

  test('封面：优先本地竖版，回退旧版 header，缺失时为 null', () {
    manifest(4000, 'Project Zomboid');
    manifest(105600, 'Terraria');
    manifest(236850, 'Eufloria HD');
    final portrait = cover(4000, 'library_600x900.jpg');
    // 105600 只有旧版的扁平 header。
    final legacyDir = Directory(
        '${library.path}\\appcache\\librarycache')..createSync(recursive: true);
    final legacy = File('${legacyDir.path}\\105600_header.jpg')
      ..writeAsBytesSync([1]);

    final games = SteamGames.scan(roots: [library.path]);
    final byName = {for (final g in games) g.name: g};

    expect(byName['Project Zomboid']!.iconFile, portrait);
    expect(byName['Terraria']!.iconFile, legacy.path);
    expect(byName['Eufloria HD']!.iconFile, isNull);
  });

  test('steam:// 路径与使用统计、钉选共用同一把键', () {
    manifest(4000, 'Project Zomboid');
    final game = SteamGames.scan(roots: [library.path]).single;
    // 键就是小写的 path —— 和快捷方式走的是同一条记录逻辑。
    expect(game.path.toLowerCase(), game.path);
    expect(game.path.startsWith('steam://rungameid/'), isTrue);
  });
}
