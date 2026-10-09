import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/state/apps_provider.dart';
import 'package:xgame_desktop/state/search_index.dart';

void main() {
  test('查询归一化：大小写、空格、连字符、全角、中文标点', () {
    expect(SearchQuery('Epic Games Launcher').flat, 'epicgameslauncher');
    expect(SearchQuery('７－Ｚｉｐ').flat, '7zip');
    expect(SearchQuery('微信（工作）').flat, '微信工作');
    expect(SearchQuery('Visual-Studio_Code').flat, 'visualstudiocode');
    expect(SearchQuery('   ').isEmpty, isTrue);
  });

  test('模糊匹配分层：精确 > 前缀 > 词首 > 首字母 > 子串 > 子序列', () {
    final keys = SearchKeys.of('Visual Studio Code');
    int? score(String q) => keys.score(SearchQuery(q));

    expect(score('visual studio code'), 1000);
    expect(score('visual'), greaterThan(score('studio')!));
    expect(score('studio'), greaterThan(score('tudi')!)); // 词首 > 子串
    expect(score('studio'), greaterThan(score('vsc')!)); // 词首 > 首字母
    expect(score('vsc'), greaterThan(score('vscode')!)); // 首字母 > 子序列
    expect(score('code visual'), isNotNull); // 词序无关
    expect(score('xyz'), isNull);
    expect(score('zz'), isNull);
  });

  test('索引按得分排序，短名优先', () {
    final index = buildSearchIndex(
        ['Steam', 'Steam Client Bootstrapper', 'Epic Games Launcher', 'Photoshop']);
    expect(index.search(SearchQuery('steam')).map((h) => h.$1), [0, 1]);
    expect(index.search(SearchQuery('phtshp')).map((h) => h.$1), [3]);
    expect(index.search(SearchQuery('egl')).map((h) => h.$1), [2]);
    expect(index.search(SearchQuery('')), isEmpty);
  });

  test('未在分类里显示的应用，搜索可以找到', () async {
    final dir = Directory.systemTemp.createTempSync('xg_search');
    final provider = AppsProvider(dataDir: dir, launcher: (_) => true)
      ..apps = [
        AppEntry(name: 'Steam', path: r'C:\a\steam.lnk', hasDesktop: true),
        AppEntry(name: 'Epic Games Launcher', path: r'C:\a\epic.lnk'),
        AppEntry(
            name: 'Developer Command Prompt for VS 2022',
            path: r'C:\a\devcmd.lnk',
            isDev: true),
        AppEntry(name: 'Visual Studio Code', path: r'C:\a\vscode.lnk'),
        AppEntry(name: '微信', path: r'C:\a\wechat.lnk'),
      ]
      ..status = AppsStatus.ready;
    await provider.buildSearchIndex();
    addTearDown(() {
      provider.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    // 两个分类都不显示它们。
    expect(provider.recommendedApps, isEmpty);
    provider.setView(AppsView.desktop);
    expect(provider.visibleApps.map((a) => a.name), ['Steam']);

    // 搜索覆盖整个目录，词序/缩写/中文都行。
    provider.setQuery('epic');
    expect(provider.visibleApps.map((a) => a.name), ['Epic Games Launcher']);
    provider.setQuery('games epic');
    expect(provider.visibleApps.map((a) => a.name), ['Epic Games Launcher']);
    provider.setQuery('vsc');
    expect(provider.visibleApps.map((a) => a.name), ['Visual Studio Code']);
    provider.setQuery('微信');
    expect(provider.visibleApps.map((a) => a.name), ['微信']);
    provider.setQuery('command prompt');
    expect(provider.visibleApps.first.name,
        'Developer Command Prompt for VS 2022');

    // 搜到之后可以照常启动，启动会把它带进「推荐」。
    final found = provider.visibleApps.first;
    expect(provider.launch(found), isTrue);
    provider.setQuery('');
    provider.setView(AppsView.recommended);
    expect(provider.visibleApps.map((a) => a.name), [found.name]);
  });

  test('索引未建好时搜索结果一致（现场算键的兜底路径）', () {
    final apps = [
      AppEntry(name: 'Steam', path: r'C:\a\steam.lnk'),
      AppEntry(name: 'Visual Studio Code', path: r'C:\a\vscode.lnk'),
      AppEntry(name: '微信（工作）', path: r'C:\a\wechat.lnk'),
    ];
    final dir = Directory.systemTemp.createTempSync('xg_search');
    final provider = AppsProvider(dataDir: dir, launcher: (_) => true)
      ..apps = apps
      ..status = AppsStatus.ready;
    addTearDown(() {
      provider.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final index = buildSearchIndex(apps.map((a) => a.name));
    for (final query in ['steam', 'vsc', '微信', 'studio code', 'code']) {
      final fromProvider = provider.searchResults(query).map((a) => a.name);
      final fromIndex = index
          .search(SearchQuery(query))
          .map((hit) => apps[hit.$1].name);
      expect(fromProvider, fromIndex, reason: '查询 "$query" 两条路径结果应一致');
    }
  });

  test('建立索引期间报告进度，完成后消失', () async {
    final dir = Directory.systemTemp.createTempSync('xg_search');
    final provider = AppsProvider(dataDir: dir, launcher: (_) => true)
      ..apps = [
        for (var i = 0; i < 3000; i++)
          AppEntry(name: 'Application Number $i', path: 'C:\\a\\app$i.lnk'),
      ]
      ..status = AppsStatus.ready;
    addTearDown(() {
      provider.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final labels = <String>[];
    provider.addListener(() {
      final p = provider.preparation;
      if (p != null) labels.add(p.label);
    });

    final build = provider.buildSearchIndex();
    // 第一片同步跑完就上报了进度，此时索引还没好。
    expect(labels, isNotEmpty);
    expect(labels.first, '正在建立搜索索引 0/3000');
    expect(provider.preparation, isNotNull);

    await build;
    // 建好后先停留在「已就绪」，不会一闪而过。
    expect(provider.preparation!.label, '搜索索引已就绪 · 3000 个应用');
    expect(provider.searchResults('application number 7').first.path,
        r'C:\a\app7.lnk');
  });
}
