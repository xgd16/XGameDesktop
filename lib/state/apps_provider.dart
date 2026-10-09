import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../data/app_activity_store.dart';
import '../data/app_database.dart';
import '../native/icon_extract.dart';
import '../native/shell_apps.dart';
import '../native/steam_games.dart';
import 'legacy_app_import.dart';
import 'search_index.dart';

enum AppsStatus { loading, ready }

/// Which slice of the app list the grid shows.
enum AppsView { recommended, games, desktop }

/// Start-menu app list: scan, background icon extraction, usage ranking,
/// search.
class AppsProvider extends ChangeNotifier {
  /// [dataDir], [launcher] and [scanner] exist so tests can rank usage without
  /// writing to the real profile, without starting any program, and without
  /// reading this machine's Start Menu.
  AppsProvider({
    Directory? dataDir,
    bool Function(String path)? launcher,
    Future<List<AppEntry>> Function()? scanner,
  })  : _dataDirOverride = dataDir,
        _launcher = launcher ?? ShellApps.launch,
        _scanner = scanner ?? scanMachine;

  final Directory? _dataDirOverride;
  final bool Function(String path) _launcher;

  /// The catalog scan. Both halves are pure file/registry reads on worker
  /// isolates, and the Steam one walks every library's manifests, so they run
  /// alongside each other rather than one behind the other.
  final Future<List<AppEntry>> Function() _scanner;

  /// What [scanner] defaults to: this machine's Start Menu and Steam library.
  static Future<List<AppEntry>> scanMachine() async {
    final (scanned, games) = await (
      Isolate.run(ShellApps.scan),
      Isolate.run(SteamGames.scan),
    ).wait;
    return [...scanned, ...games];
  }

  static Directory get _defaultDataDir {
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return Directory('$base\\XGameDesktop');
  }

  Directory get _dataDir => _dataDirOverride ?? _defaultDataDir;
  String get _iconDir => '${_dataDir.path}\\icons';

  /// The open profile database and its activity tables — opened on first use,
  /// released by [dispose].
  AppDatabase? _db;
  AppActivityStore? _activity;

  AppsStatus status = AppsStatus.loading;

  List<AppEntry> _apps = [];

  /// The scanned catalog. Assigning a new list drops the memoized views, which
  /// is what keeps [visibleApps] honest for anything that swaps the catalog in
  /// (the loader, and tests driving the provider by hand).
  List<AppEntry> get apps => _apps;
  set apps(List<AppEntry> value) {
    _apps = value;
    _invalidateVisible();
  }

  Timer? _iconFlush;
  bool _iconsDirty = false;
  bool _disposed = false;

  /// How many icons the background worker has reported — hits and misses
  /// alike, because a miss is a finished extraction too. Out of
  /// [iconsTotal]; both are 0 until the scan is done.
  int _iconsDone = 0;
  int _iconsTotal = 0;

  int get iconsDone => _iconsDone;
  int get iconsTotal => _iconsTotal;

  /// 0..1 over the whole catalog. One with nothing to extract, which is what
  /// "waiting for the icons" means on a machine with no apps.
  double get iconProgress => _iconsTotal == 0 ? 1 : _iconsDone / _iconsTotal;

  /// Precomputed search keys; null until the background build finishes (search
  /// works meanwhile, computing keys on the fly).
  AppSearchIndex? _index;
  int _indexDone = 0;
  int _indexTotal = 0;

  /// Whether the index pass is over — or there is nothing to index. What the
  /// opening screen waits on: searching before it lands works, but scores
  /// every name on the fly.
  bool get searchIndexReady => _index != null || _indexTotal == 0;

  /// Keeps the finished index line on screen for a moment so a fast build does
  /// not flash by unseen.
  Timer? _prepHold;

  /// Launch history by app path (lowercased) — what "推荐" ranks by, and what
  /// the statistics page lists.
  final Map<String, LaunchRecord> _launches = {};

  /// Pinned apps as lowercased path keys, front of the grid first. The same
  /// key the launch history uses, so a Steam game's `steam://` path pins just
  /// as a shortcut's does.
  final List<String> _pins = [];

  String _query = '';
  String get query => _query;
  AppsView view = AppsView.recommended;

  /// The category the chips filter by — null shows everything. A session
  /// filter, not a preference: nothing persists it.
  AppCategory? activeCategory;

  // Memoized views of [apps] — see [visibleApps].
  List<AppEntry>? _visible;
  String? _visibleQuery;
  AppsView? _visibleView;
  AppCategory? _visibleCategory;
  List<AppEntry>? _recommended;
  int? _desktopCount;
  Map<AppCategory, int> _categoryCounts = const {};

  /// The catalog by lower-cased path — what ties a launch record or a pinned
  /// key back to an installed entry. Rebuilt lazily whenever either changes.
  Map<String, AppEntry>? _byKey;

  /// The launch history in statistics order — see [launchHistory].
  List<LaunchRecord>? _history;

  Map<String, AppEntry> get _catalogByKey =>
      _byKey ??= {for (final app in apps) _usageKey(app): app};

  Future<void> load() async {
    await _loadActivity();
    apps = await _scanner();
    status = AppsStatus.ready;
    notifyListeners();
    _nameImportedLaunches();
    _extractIconsInBackground();
    buildSearchIndex();
  }

  /// Gives a name to the launch records that have none — the counts imported
  /// off `usage.json`, which was a bare `{path: count}`.
  ///
  /// The catalog is what knows the names, and it is only read after the scan,
  /// which is why this runs behind it. An app that is already gone keeps its
  /// empty name and reads off the path instead (see
  /// [LaunchRecord.displayName]), which is the truth rather than a guess.
  void _nameImportedLaunches() {
    final byKey = _catalogByKey;
    final named = <(String, String)>[
      for (final row in _launches.values)
        if (row.name.isEmpty)
          if (byKey[row.key] case final entry?) (row.key, entry.name),
    ];
    if (named.isEmpty) return;
    for (final (key, name) in named) {
      try {
        final updated = _activityStore().setLaunchName(key, name);
        if (updated != null) _launches[key] = updated;
      } catch (_) {}
    }
  }

  /// Reduces every app name to search keys, in ~8 ms slices so the UI keeps
  /// painting between them and can show progress. Callers do not wait for it:
  /// searching before it lands scores freshly computed keys instead.
  Future<void> buildSearchIndex() async {
    final total = apps.length;
    _indexTotal = total;
    _indexDone = 0;
    _index = null;
    // Queries are scored on the fly until the index lands; the results differ.
    _invalidateVisible();
    notifyListeners();
    if (total == 0) {
      _index = AppSearchIndex.empty();
      return;
    }
    final builder = AppSearchIndexBuilder();
    final slice = Stopwatch()..start();
    for (var i = 0; i < total; i++) {
      if (_disposed) return;
      builder.add(apps[i].name);
      _indexDone = i + 1;
      if (slice.elapsedMilliseconds >= 8 || i == total - 1) {
        notifyListeners();
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    // The loop above yields between slices, so the provider can be released
    // while it runs — the last await is a gap like any other, and everything
    // from here to the end touches a disposed notifier.
    if (_disposed) return;
    _index = builder.build();
    // Search results change with the index (they are scored from it).
    _invalidateVisible();
    _prepHold?.cancel();
    _prepHold = Timer(const Duration(milliseconds: 900), () {
      _prepHold = null;
      if (_disposed) return;
      notifyListeners();
    });
    notifyListeners();
  }

  /// What the search field shows while the catalog is being prepared. The
  /// index build is quick, so the finished state is held briefly rather than
  /// blinking past.
  ({String label, double value})? get preparation {
    if (_indexTotal == 0) return null;
    if (_indexDone < _indexTotal) {
      return (
        label: '正在建立搜索索引 $_indexDone/$_indexTotal',
        value: _indexDone / _indexTotal,
      );
    }
    if (_prepHold != null) {
      return (label: '搜索索引已就绪 · $_indexTotal 个应用', value: 1);
    }
    return null;
  }

  /// Icons stream in one by one so the grid fills in with a staggered fade
  /// instead of blocking first paint. Steam games have no shortcut icon to
  /// pull — their cover art arrives on its own — so only the .lnk/.url
  /// entries go through the pipeline, and the worker's results are mapped
  /// back through the slot list that produced them.
  Future<void> _extractIconsInBackground() async {
    final slots = <int>[];
    final paths = <String>[];
    for (var i = 0; i < apps.length; i++) {
      if (!apps[i].isGame) {
        slots.add(i);
        paths.add(apps[i].path);
      }
    }
    if (paths.isEmpty) return;
    _iconsTotal = paths.length;
    _iconsDone = 0;
    final receive = ReceivePort();
    await Isolate.spawn(
      _iconWorker,
      (receive.sendPort, paths, _iconDir),
    );
    receive.listen((message) {
      if (message is! List || message.length != 2) return;
      final index = message[0] as int;
      final iconPath = message[1] as String?;
      if (index >= 0 &&
          index < slots.length &&
          slots[index] < apps.length &&
          apps[slots[index]].path == paths[index]) {
        apps[slots[index]].iconFile = iconPath;
        _iconsDone++;
        _scheduleIconFlush();
      }
    });
  }

  /// Icons land one at a time, and rebuilding the grid for every single one
  /// makes a long list stutter. Arrivals are flushed in ~100 ms groups: the
  /// grid still fills in progressively, at a tenth of the rebuilds.
  void _scheduleIconFlush() {
    _iconsDirty = true;
    _iconFlush ??= Timer(const Duration(milliseconds: 100), () {
      _iconFlush = null;
      if (_disposed || !_iconsDirty) return;
      _iconsDirty = false;
      notifyListeners();
    });
  }

  static void _iconWorker((SendPort, List<String>, String) args) {
    final (send, paths, iconDir) = args;
    for (var i = 0; i < paths.length; i++) {
      String? icon;
      try {
        icon = extractIconToCache(paths[i], iconDir, kIconRequestSize);
      } catch (_) {}
      send.send([i, icon]);
    }
  }

  // ---- launch history ----

  /// The activity tables, opening the database the first time it is asked for.
  ///
  /// A profile that has never run the import still has everything its old
  /// `usage.json` and `pins.json` knew; `once` records that it ran, in the
  /// database itself, so clearing the statistics cannot bring them back.
  AppActivityStore _activityStore() {
    final open = _activity;
    if (open != null) return open;
    final db = AppDatabase.open(_dataDir);
    try {
      final store = db.activityStore();
      db.once(AppDatabase.activityImportFlag,
          () => importLegacyAppActivity(store, _dataDir));
      _db = db;
      return _activity = store;
    } catch (_) {
      // Nothing keeps the connection if the first use of it failed.
      db.close();
      rethrow;
    }
  }

  /// Reads the launch history and the pinned row back into memory.
  ///
  /// Both are asked for on every rebuild — the ranking sorts by them — so the
  /// tables are read once here and written through on each change rather than
  /// queried per tile.
  Future<void> _loadActivity() async {
    try {
      final store = _activityStore();
      _launches
        ..clear()
        ..addEntries(store.launches().map((row) => MapEntry(row.key, row)));
      _pins
        ..clear()
        ..addAll(store.pinned());
    } catch (_) {}
  }

  static String _usageKey(AppEntry app) => app.path.toLowerCase();

  /// How often [app] has been opened.
  int launchCount(AppEntry app) => _launches[_usageKey(app)]?.launches ?? 0;

  /// The whole history, most opened first and by name within a tie — what the
  /// statistics page lists. Memoized, like the visible grid.
  List<LaunchRecord> get launchHistory {
    final cached = _history;
    if (cached != null) return cached;
    final rows = _launches.values.toList()
      ..sort((a, b) {
        final byCount = b.launches.compareTo(a.launches);
        return byCount != 0
            ? byCount
            : a.displayName.compareTo(b.displayName);
      });
    return _history = rows;
  }

  /// Every launch ever recorded, across every app.
  int get totalLaunches {
    var total = 0;
    for (final row in _launches.values) {
      total += row.launches;
    }
    return total;
  }

  /// The scanned entry a history row belongs to, or null when that app is not
  /// in the catalog any more — uninstalled, or a shortcut that moved. The
  /// statistics page falls back to the name the row kept.
  AppEntry? catalogEntry(String key) => _catalogByKey[key];

  /// Counts one launch of [app].
  ///
  /// The count moves in memory first, so the grid re-ranks on the same frame
  /// even if the write below fails; the row the database hands back then
  /// reconciles the two.
  void recordLaunch(AppEntry app) {
    final key = _usageKey(app);
    final now = DateTime.now().toUtc();
    final previous = _launches[key];
    _launches[key] = LaunchRecord(
      key: key,
      name: app.name,
      launches: (previous?.launches ?? 0) + 1,
      firstLaunch: previous?.firstLaunch ?? now,
      lastLaunch: now,
      createTime: previous?.createTime ?? now,
      updateTime: now,
    );
    // Both views are ranked by launch count.
    _invalidateVisible();
    notifyListeners();
    try {
      _launches[key] = _activityStore().countLaunch(key, app.name);
    } catch (_) {}
  }

  /// Throws the whole launch history away — the statistics page's "clear".
  /// Pinned apps are untouched: that is an arrangement, not a statistic.
  void clearLaunchStats() {
    if (_launches.isEmpty) return;
    _launches.clear();
    _invalidateVisible();
    notifyListeners();
    try {
      _activityStore().clearLaunches();
    } catch (_) {}
  }

  // ---- pinned apps ----

  bool isPinned(AppEntry app) => _pins.contains(_usageKey(app));

  /// Pins [app]: it leads every view's grid, in pin order — a home row the
  /// user arranges themselves. A pinned app shows up even if it was never
  /// launched, so pinning is also how a rarely used but important tool gets a
  /// permanent seat.
  void pin(AppEntry app) {
    final key = _usageKey(app);
    if (_pins.contains(key)) return;
    _pins.add(key);
    _invalidateVisible();
    notifyListeners();
    _savePins();
  }

  void unpin(AppEntry app) {
    if (!_pins.remove(_usageKey(app))) return;
    _invalidateVisible();
    notifyListeners();
    _savePins();
  }

  /// Steps a pinned app [delta] slots within the pinned block — the pad's way
  /// to arrange the home row. No-op when the app is not pinned or the step
  /// would leave the block.
  void movePin(AppEntry app, int delta) {
    final at = _pins.indexOf(_usageKey(app));
    if (at < 0) return;
    final to = (at + delta).clamp(0, _pins.length - 1);
    if (to == at) return;
    _pins.removeAt(at);
    _pins.insert(to, _usageKey(app));
    _invalidateVisible();
    notifyListeners();
    _savePins();
  }

  /// Mirrors the in-memory arrangement into `app_pin`. The list is the source
  /// of truth for the order — pinning, unpinning and stepping a row along all
  /// edit it — so this writes the whole arrangement rather than a delta.
  void _savePins() {
    try {
      _activityStore().setPins(_pins);
    } catch (_) {}
  }

  // ---- filtering ----

  void setQuery(String q) {
    _query = q;
    notifyListeners();
  }

  void setView(AppsView value) {
    if (view == value) return;
    view = value;
    notifyListeners();
  }

  void setCategory(AppCategory? value) {
    if (activeCategory == value) return;
    activeCategory = value;
    _invalidateVisible();
    notifyListeners();
  }

  /// What "推荐" is made of: the pinned apps — even ones never launched — plus
  /// everything opened at least once. Membership only; the pin-first order is
  /// [_rank]'s business when the visible list is built.
  List<AppEntry> get recommendedApps {
    if (_recommended != null) return _recommended!;
    final byKey = _catalogByKey;
    // A pin whose app is gone (uninstalled, or a stale key) is simply absent.
    final pinned = [for (final key in _pins) ?byKey[key]];
    return _recommended = [
      ...pinned,
      ...apps.where((a) => launchCount(a) > 0 && !isPinned(a)),
    ];
  }

  /// The visible list, memoized.
  ///
  /// It is asked for from `build`, and this provider notifies far more often
  /// than the list can change — an icon flush every 100 ms while the cache is
  /// cold, an index slice every ~8 ms. Without the cache, each of those
  /// notifications re-filtered the catalog, re-sorted it with two `toLowerCase`
  /// allocations per comparison, and re-scanned it twice for the tab counts.
  ///
  /// The returned list is the cache itself: callers must not modify it.
  List<AppEntry> get visibleApps {
    final q = _query.trim();
    final cached = _visible;
    if (cached != null &&
        _visibleQuery == q &&
        _visibleView == view &&
        _visibleCategory == activeCategory) {
      return cached;
    }
    final list = _computeVisible(q);
    _visible = list;
    _visibleQuery = q;
    _visibleView = view;
    _visibleCategory = activeCategory;
    return list;
  }

  List<AppEntry> _computeVisible(String q) {
    // A query searches the whole catalog — including the apps neither tab
    // shows — so anything installed stays reachable by typing. On the games
    // shelf the results stay games: the cover wall has no room for a utility
    // that merely matched, and the other tabs still show everything.
    if (q.isNotEmpty) {
      final results = searchResults(q);
      return view == AppsView.games
          ? results.where((a) => a.isGame).toList()
          : results;
    }
    final Iterable<AppEntry> list = switch (view) {
      AppsView.recommended => recommendedApps,
      // The shelf is its own filter — the category chips do not apply here.
      AppsView.games => games,
      AppsView.desktop => apps.where((a) => a.hasDesktop),
    };
    final filtered =
        activeCategory == null || view == AppsView.games
            ? list
            : list.where((a) => a.category == activeCategory);
    return filtered.toList()..sort(rank);
  }

  /// The grid's order: pinned apps lead in pin order, the rest rank by how
  /// often they were opened, name as tie-break so the order never wobbles
  /// between rebuilds.
  int rank(AppEntry a, AppEntry b) {
    final pa = _pins.indexOf(_usageKey(a));
    final pb = _pins.indexOf(_usageKey(b));
    if (pa >= 0 || pb >= 0) {
      if (pa < 0) return 1;
      if (pb < 0) return -1;
      return pa - pb;
    }
    final ua = launchCount(a);
    final ub = launchCount(b);
    if (ua != ub) return ub - ua;
    return a.name.compareTo(b.name);
  }

  /// Anything the visible list is built from changed: the catalog, a launch
  /// count, the pins, the category filter, or the search index it prefers.
  /// Cheap — the next read recomputes.
  void _invalidateVisible() {
    _visible = null;
    _visibleQuery = null;
    _visibleView = null;
    _visibleCategory = null;
    _recommended = null;
    _desktopCount = null;
    _gamesCount = null;
    _categoryCounts = const {};
    _byKey = null;
    _history = null;
  }

  /// Fuzzy, ranked search over every scanned app. Match quality leads; how
  /// often the app has been opened breaks ties, then the name.
  List<AppEntry> searchResults(String rawQuery) {
    final query = SearchQuery(rawQuery);
    if (query.isEmpty) return const [];
    final index = _index;
    final hits = <(int, AppEntry)>[];
    if (index != null && index.length == apps.length) {
      // Unranked: the sort below is the ranking, and it is the only one worth
      // paying for.
      for (final (i, score) in index.score(query)) {
        hits.add((score, apps[i]));
      }
    } else {
      for (final app in apps) {
        final score = SearchKeys.of(app.name).score(query);
        if (score != null) hits.add((score, app));
      }
    }
    hits.sort((a, b) {
      if (a.$1 != b.$1) return b.$1 - a.$1;
      final ua = launchCount(a.$2);
      final ub = launchCount(b.$2);
      if (ua != ub) return ub - ua;
      return a.$2.name.compareTo(b.$2.name);
    });
    return [for (final (_, app) in hits) app];
  }

  int get recommendedCount => recommendedApps.length;

  int get desktopCount =>
      _desktopCount ??= apps.where((a) => a.hasDesktop).length;

  int? _gamesCount;

  /// How many Steam games the scan found — zero means no Steam (or an empty
  /// library), which is what keeps the 游戏 tab and its LB/RB stop away.
  int get gamesCount =>
      _gamesCount ??= apps.where((a) => a.isGame).length;

  List<AppEntry> get games => apps.where((a) => a.isGame).toList();

  /// The tabs the toggle shows and LB/RB walks. 游戏 needs something behind
  /// it; the other two are always there.
  List<AppsView> get availableViews =>
      gamesCount > 0
          ? AppsView.values
          : const [AppsView.recommended, AppsView.desktop];

  AppsView? _countsView;

  /// Per-category size of the view the chips are filtering — 推荐 counts its
  /// launched-and-pinned, 桌面 its desktop shortcuts. A count that described
  /// the whole catalog would promise the list it never shows (the games shelf
  /// saying 全部 115 over two tiles), so the numbers always answer "what is
  /// in the list in front of me".
  Map<AppCategory, int> get categoryCounts {
    if (_countsView != view || _categoryCounts.isEmpty) {
      final Iterable<AppEntry> list = switch (view) {
        AppsView.recommended => recommendedApps,
        AppsView.games => games,
        AppsView.desktop => apps.where((a) => a.hasDesktop),
      };
      final counts = {for (final c in AppCategory.values) c: 0};
      for (final app in list) {
        counts[app.category] = counts[app.category]! + 1;
      }
      _categoryCounts = counts;
      _countsView = view;
    }
    return _categoryCounts;
  }

  // ---- actions ----

  bool launch(AppEntry app) {
    final launched = _launcher(app.path);
    if (launched) recordLaunch(app);
    return launched;
  }

  bool openLocation(AppEntry app) => ShellApps.openLocation(app.path);

  /// Games whose cover was already asked for — the CDN is given one shot per
  /// game per session, so a tile that scrolls by a hundred times costs one
  /// miss, not a hundred.
  final Set<String> _coverTried = {};

  /// Fetches [game]'s portrait from Steam's CDN when the local library cache
  /// had none, and keeps it in `dataDir\games` so every later session draws
  /// from disk. Returns the path once it exists, null offline — the tile then
  /// stays on its letter block and nothing retries.
  Future<String?> fetchGameCover(AppEntry game) async {
    if (!game.isGame || game.iconFile != null) return game.iconFile;
    final id = int.tryParse(game.path.substring(game.path.lastIndexOf('/') + 1));
    if (id == null) return null;
    if (!_coverTried.add(game.path)) return game.iconFile;

    final dir = Directory('${_dataDir.path}\\games');
    final cached = File('${dir.path}\\$id.jpg');
    if (cached.existsSync()) {
      game.iconFile = cached.path;
      return game.iconFile;
    }
    for (final name in const [
      'library_600x900_2x.jpg',
      'library_600x900.jpg',
      'header.jpg',
    ]) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 4);
        final request = await client.getUrl(Uri.parse(
            'https://cdn.cloudflare.steamstatic.com/steam/apps/$id/$name'));
        final response = await request.close();
        if (response.statusCode != 200) continue;
        final bytes = BytesBuilder();
        await for (final chunk in response) {
          bytes.add(chunk);
        }
        await dir.create(recursive: true);
        await cached.writeAsBytes(bytes.takeBytes(), flush: true);
        game.iconFile = cached.path;
        return game.iconFile;
      } catch (_) {
        // Offline, or the shape of the answer is wrong — the next candidate
        // gets its turn.
      }
    }
    return null;
  }

  @override
  void dispose() {
    // Idempotent: the profile database goes with the provider, and a caller
    // that releases its apps early — a test, or a screen torn down by hand —
    // must not turn a second release into an error.
    if (_disposed) return;
    _disposed = true;
    _iconFlush?.cancel();
    _iconFlush = null;
    _prepHold?.cancel();
    _prepHold = null;
    _db?.close();
    _db = null;
    _activity = null;
    super.dispose();
  }
}
