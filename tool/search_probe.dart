// Dev-only probe: runs the production scan + search index against this
// machine's real Start Menu and prints ranked hits, plus a self-check that
// every entry the tabs hide is still reachable by a fuzzy query.
// Run: dart run tool/search_probe.dart [query ...]
// ignore_for_file: avoid_print
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/state/search_index.dart';

void main(List<String> args) {
  final apps = ShellApps.scan();
  final index = buildSearchIndex(apps.map((a) => a.name));
  final hidden = apps.where((a) => !a.hasDesktop).toList();
  print('共 ${apps.length} 个条目，其中 ${hidden.length} 个不在桌面上（两个分类都不显示）');

  void show(String query) {
    final hits = index.search(SearchQuery(query)).take(6).toList();
    final text = hits.isEmpty
        ? '无结果'
        : hits.map((h) => '${apps[h.$1].name} [${h.$2}]').join('  |  ');
    print('  "$query" -> $text');
  }

  print('\n示例查询:');
  for (final q in args) {
    show(q);
  }
  if (args.isEmpty) {
    for (final q in ['vsc', 'cmd', '7z', 'wechat', 'devenv', 'phtshp']) {
      show(q);
    }
  }

  // 自检：每个隐藏条目都应能被「首字母缩写」和「名字片段」找到。
  var checks = 0;
  var misses = 0;
  for (final app in hidden) {
    final keys = SearchKeys.of(app.name);
    final queries = <String>{
      if (keys.acronym.length >= 2) keys.acronym,
      keys.flat.length >= 4
          ? keys.flat.substring(0, 4)
          : keys.flat,
    };
    for (final q in queries) {
      if (q.isEmpty) continue;
      checks++;
      final hit = index
          .search(SearchQuery(q))
          .take(8)
          .any((h) => apps[h.$1].name == app.name);
      if (!hit) {
        misses++;
        print('  未命中: "${app.name}" 查 "$q"');
      }
    }
  }
  print('\n隐藏条目自检: $checks 次查询, $misses 次未命中');
}
