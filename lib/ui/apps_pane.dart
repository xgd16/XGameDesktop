import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../native/shell_apps.dart' show AppCategory, AppEntry;
import '../state/apps_provider.dart';
import 'app_card.dart';
import 'game_card.dart';
import 'keyboard_overlay.dart';
import 'nav.dart';
import 'widgets.dart';

/// Left pane: search, filter toggle, and the app grid.
class AppsPane extends StatefulWidget {
  const AppsPane({super.key, this.onKeyboardChanged, this.revealed = true});

  /// Tells the shell whether the soft keyboard is up: the pad hint strip has
  /// to get out of its way.
  final ValueChanged<bool>? onKeyboardChanged;

  /// False while the boot screen covers the window. The wave is the second half
  /// of that one boot-up sequence, so it is held back rather than played
  /// unseen: the tiles stand still behind the field and land as it splits.
  final bool revealed;

  @override
  State<AppsPane> createState() => AppsPaneState();
}

/// Hands out the staggered entrance delay for one grid.
///
/// Grid children are recycled: scrolling builds tiles that were never on
/// screen, and letting each of them replay the boot-up fade reads as flicker —
/// the more apps, the worse. So only the tiles of the first laid-out frame take
/// part in the sequence, and they take strictly increasing slots: the whole
/// screen sweeps once instead of restarting the stagger every 24 tiles.
class _EntranceGate {
  var _open = true;
  var _scheduled = false;
  var _slot = 0;

  /// Null once the boot wave has passed: the tile then appears at rest.
  Duration? nextDelay() => _open ? Motion.staggerDelay(_slot++) : null;

  /// Called while building the grid; shuts the wave after this frame.
  void closeAfterThisFrame() {
    if (!_open || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _open = false);
  }

  /// Counts from the first slot again. A wave that was held back has not handed
  /// out a single delay yet, but one that is resumed after a pass — the boot
  /// screen being dismissed late, say — would otherwise start mid-sweep.
  void restart() {
    _open = true;
    _scheduled = false;
    _slot = 0;
  }
}

class AppsPaneState extends State<AppsPane> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode(debugLabel: 'search');
  final _gridController = ScrollController();
  final _entrance = _EntranceGate();

  /// One focus node per grid slot, so the pad's highlight can be aimed at a
  /// tile by index. The nodes outlive the tiles that come and go with
  /// scrolling; only the attached ones answer.
  final Map<int, FocusNode> _cardNodes = {};

  /// The keyboard itself, so the shell can aim the pad at its keys.
  final _kbKey = GlobalKey<SoftKeyboardState>();

  bool _searchFocused = false;
  bool _keyboardOpen = false;

  /// The three panels above the grid frost the wallpaper and nothing else, so
  /// they share one backdrop: the engine reads and blurs it once for all of
  /// them instead of once each. Held here rather than made per build — a fresh
  /// key every rebuild would defeat the sharing it exists for.
  final _frostKey = BackdropKey();

  FocusNode _cardNode(int index) =>
      _cardNodes.putIfAbsent(index, () => FocusNode(debugLabel: 'app$index'));

  /// Puts the highlight on the first tile currently on screen — where a pad
  /// that just woke up, or a shell that just left a full-screen page, should
  /// start. Falls back to the search field when there is no tile to land on.
  void focusFirst() {
    // The keyboard floats over the grid and keeps the tiles out of the focus
    // order while it is up, so reaching the grid first puts it away. That is
    // a setState: the tiles answer focus requests again only once that
    // rebuild has landed, so the request waits for the next frame — asking
    // before it is a silent no-op.
    if (_keyboardOpen) {
      closeKeyboard();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusFirstTile();
      });
      return;
    }
    _focusFirstTile();
  }

  void _focusFirstTile() {
    final live = _liveCards();
    if (live.isEmpty) {
      _focusNode.requestFocus();
      return;
    }
    _aimAt(live.first.value);
  }

  /// Puts the pad's highlight on the search field — the page's first row.
  /// The shell sends a move down from the title bar here: the bar spans the
  /// window, and the geometric walk below it landed on the telemetry column,
  /// whose edge is not a ring anybody reads as a cursor.
  void focusSearch() => _focusNode.requestFocus();

  /// The grid slot the pad's highlight sits on, or null when it is elsewhere.
  int? get focusedCardIndex {
    for (final entry in _cardNodes.entries) {
      if (entry.value.hasFocus) return entry.key;
    }
    return null;
  }

  /// Opens the focused card's context menu — the pad's Start button on a tile,
  /// the way it reaches pinning and the file's folder. Returns false when the
  /// highlight is not on a card, so the shell can fall back to the settings
  /// page.
  bool showFocusedCardMenu() {
    final index = focusedCardIndex;
    if (index == null) return false;
    final visible = context.read<AppsProvider>().visibleApps;
    if (index >= visible.length) return false;
    final node = _cardNodes[index];
    final box = node?.context?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return false;
    showAppMenu(
        context, visible[index], box.localToGlobal(box.size.center(Offset.zero)));
    return true;
  }

  /// Puts the highlight back on the grid after the visible list changed under
  /// it: switching views can take the card it sat on away, and a node that is
  /// gone leaves the highlight nowhere. Keeps [slot] when the new list still
  /// reaches it, drops to the last card when the new view is shorter, and to
  /// the search field when the view came up empty.
  void restoreGridFocus(int slot) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final live = _liveCards();
      if (live.isEmpty) {
        _focusNode.requestFocus();
        return;
      }
      _aimAt(live
          .firstWhere((entry) => entry.key >= slot, orElse: () => live.last)
          .value);
    });
  }

  /// The card nodes that are really in the focus tree, in grid order.
  ///
  /// A card that scrolled out of view — or whose slot the new view no longer
  /// reaches — is unmounted and its node detached, but the node keeps the
  /// [FocusNode.context] it was attached with, stale element and all. Only
  /// the focus tree tells whether a node is still there.
  List<MapEntry<int, FocusNode>> _liveCards() => _cardNodes.entries
      .where((entry) => entry.value.parent != null)
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  /// Hands the highlight to [node] and brings it into view.
  void _aimAt(FocusNode node) {
    final context = node.context;
    node.requestFocus();
    if (context != null && context.mounted) revealFocus(context);
  }

  void openKeyboard() {
    setState(() => _keyboardOpen = true);
    widget.onKeyboardChanged?.call(true);
    // The pad starts picking keys the moment the keyboard is up — the request
    // waits for the frame that mounts it. A real keyboard typing into the
    // field keeps its focus; a stick push down still walks into the keys.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _keyboardOpen && !_searchFocused) {
        _kbKey.currentState?.focusFirstKey();
      }
    });
  }

  /// True while the pad's highlight sits on one of the keyboard's keys.
  bool get keyboardFocused => _kbKey.currentState?.hasFocus ?? false;

  /// Puts the pad's highlight on the keyboard's first key.
  void focusKeyboard() => _kbKey.currentState?.focusFirstKey();

  void closeKeyboard() {
    if (!_keyboardOpen) return;
    setState(() => _keyboardOpen = false);
    widget.onKeyboardChanged?.call(false);
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() => _searchFocused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    _gridController.dispose();
    for (final node in _cardNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final apps = context.watch<AppsProvider>();
    final visible = apps.visibleApps;
    final preparation = apps.preparation;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      // One backdrop for the three panels above the grid: they sit on the
      // wallpaper with nothing of the app between them and it, so a single
      // read of it serves all three.
      child: BackdropGroup(
        backdropKey: _frostKey,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: _buildSearchField(c, preparation)),
                    const SizedBox(width: 12),
                    _buildSegmentedToggle(c, apps),
                  ],
                ),
                // The chips only make sense on the browsable views, and only
                // when nothing is typed: a query searches the whole catalog and
                // answers by relevance, not by shelf, and the games shelf is
                // already a filter of its own.
                if (apps.status == AppsStatus.ready &&
                    apps.view != AppsView.games &&
                    apps.query.trim().isEmpty) ...[
                  const SizedBox(height: 10),
                  _buildCategoryChips(c, apps),
                ],
                const SizedBox(height: 16),
                Expanded(
                  child: apps.status == AppsStatus.loading
                      ? _buildLoading(c)
                      : visible.isEmpty
                          ? _buildEmpty(c, apps)
                          : _buildGrid(visible),
                ),
              ],
            ),
            // The keyboard floats over the grid instead of pushing it around:
            // the results have to stay put while the query is typed.
            if (_keyboardOpen)
              Positioned(
                left: 0,
                right: 0,
                bottom: 10,
                child: SoftKeyboard(
                  key: _kbKey,
                  controller: _searchController,
                  onChanged: apps.setQuery,
                  onClose: closeKeyboard,
                  onExitUp: () => _focusNode.requestFocus(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField(
      AppColors c, ({String label, double value})? preparation) {
    // Frosted rather than filled: the field sits on the desktop, so the
    // wallpaper stays readable through it and the box still holds its edge.
    return TouchTarget(
      minSize: const Size(44, 44),
      child: Frosted(
        radius: 12,
        wallpaperOnly: true,
        child: AnimatedContainer(
          duration: Motion.base,
          curve: Motion.outCubic,
          height: 42,
          decoration: BoxDecoration(
            color: c.frost,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _searchFocused || _keyboardOpen ? c.accent : c.border,
              width: 1.1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // The field also carries the background work's progress: a hairline
          // along its bottom edge, with the count standing in as the hint until
          // the index and icon passes are done.
          child: Stack(
            fit: StackFit.expand,
            children: [
              Row(
                children: [
                  AnimatedSwitcher(
                    duration: Motion.base,
                    child: Icon(
                      Icons.search,
                      key: ValueKey(_searchFocused),
                      size: 18,
                      color: _searchFocused ? c.accent : c.textMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    // A on the focused field opens the soft keyboard, the same
                    // as the key button beside it: the field itself has no
                    // Enter to press and a couch has nothing to type with.
                    child: Actions(
                      actions: {
                        ActivateIntent: CallbackAction<ActivateIntent>(
                          onInvoke: (_) {
                            openKeyboard();
                            return null;
                          },
                        ),
                      },
                      child: TextField(
                        controller: _searchController,
                        focusNode: _focusNode,
                        onChanged: context.read<AppsProvider>().setQuery,
                        style: TextStyle(fontSize: 13, color: c.textPrimary),
                        cursorColor: c.accent,
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: preparation?.label ?? '搜索应用',
                          hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
                        ),
                      ),
                    ),
                  ),
                  if (_searchController.text.isNotEmpty)
                    Tappable(
                      onTap: () {
                        _searchController.clear();
                        context.read<AppsProvider>().setQuery('');
                      },
                      tooltip: '清空',
                      builder: (context, state) => AnimatedContainer(
                        duration: Motion.base,
                        curve: Motion.outCubic,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color:
                                state.focused ? c.accent : Colors.transparent,
                          ),
                        ),
                        child: Icon(
                          Icons.close,
                          size: 15,
                          color: state.highlighted ? c.textPrimary : c.textMuted,
                        ),
                      ),
                    ),
                  const SizedBox(width: 2),
                  Tappable(
                    onTap: openKeyboard,
                    tooltip: '屏幕键盘',
                    builder: (context, state) => AnimatedContainer(
                      duration: Motion.base,
                      curve: Motion.outCubic,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: state.focused ? c.accent : Colors.transparent,
                        ),
                      ),
                      child: Icon(
                        Icons.keyboard_alt_outlined,
                        size: 17,
                        color: _keyboardOpen
                            ? c.accent
                            : state.highlighted
                                ? c.textPrimary
                                : c.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
              if (preparation != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(1),
                    child: LinearProgressIndicator(
                      value: preparation.value,
                      minHeight: 2,
                      color: c.accent,
                      backgroundColor: c.barTrack,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSegmentedToggle(AppColors c, AppsProvider apps) {
    // Same frost as the field beside it: one glass strip, two sheets.
    return TouchTarget(
      minSize: const Size(44, 44),
      child: Frosted(
        radius: 12,
        wallpaperOnly: true,
        child: Container(
          height: 42,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: c.frost,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final view in apps.availableViews)
                _segment(c, _viewLabel(view, apps), apps.view == view,
                    () => apps.setView(view)),
            ],
          ),
        ),
      ),
    );
  }

  String _viewLabel(AppsView view, AppsProvider apps) => switch (view) {
        AppsView.recommended => '推荐 ${apps.recommendedCount}',
        AppsView.games => '游戏 ${apps.gamesCount}',
        AppsView.desktop => '桌面 ${apps.desktopCount}',
      };

  Widget _segment(AppColors c, String label, bool selected, VoidCallback onTap) {
    return Tappable(
      onTap: onTap,
      builder: (context, state) => AnimatedContainer(
        duration: Motion.base,
        curve: Motion.outCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? c.accentDim : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          // Always there, transparent at rest: the ring cannot shift the label
          // when the pad arrives.
          border: Border.all(
            color: state.focused ? c.accent : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? c.accent
                : state.highlighted
                    ? c.textPrimary
                    : c.textMuted,
          ),
        ),
      ),
    );
  }

  /// The category filter: one glass strip of pills under the search row, the
  /// toggle's own design language at a smaller scale. Counts come from the
  /// view being filtered, not the catalog, and a category with nothing in it
  /// takes no pill — an empty shelf is not a choice.
  Widget _buildCategoryChips(AppColors c, AppsProvider apps) {
    final counts = apps.categoryCounts;
    final options = <(AppCategory?, String)>[
      (null, '全部'),
      if ((counts[AppCategory.game] ?? 0) > 0)
        (AppCategory.game, '游戏 ${counts[AppCategory.game]}'),
      if ((counts[AppCategory.app] ?? 0) > 0)
        (AppCategory.app, '应用 ${counts[AppCategory.app]}'),
      if ((counts[AppCategory.dev] ?? 0) > 0)
        (AppCategory.dev, '开发 ${counts[AppCategory.dev]}'),
      if ((counts[AppCategory.system] ?? 0) > 0)
        (AppCategory.system, '系统 ${counts[AppCategory.system]}'),
    ];
    // Nothing to filter by — every entry is one category and the strip would
    // only repeat the toggle beside the search field.
    if (options.length <= 2) return const SizedBox.shrink();
    return TouchTarget(
      minSize: const Size(44, 44),
      child: Frosted(
        radius: 12,
        wallpaperOnly: true,
        child: Container(
          height: 38,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: c.frost,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (category, label) in options)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _segment(c, label, apps.activeCategory == category,
                        () => apps.setCategory(category)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(List<AppEntry> visible) {
    final apps = context.read<AppsProvider>();
    // The wave belongs to the boot sequence, so it is held while the boot
    // screen is up — and the grid is keyed on [AppsPane.revealed], which
    // remounts the tiles once when the field splits: an entrance that has
    // already played cannot run again any other way, and a wave nobody sees is
    // the same as no wave at all.
    if (widget.revealed) {
      _entrance.closeAfterThisFrame();
    } else {
      _entrance.restart();
    }
    // A finger scrolling the grid is also how it says "stop typing": the
    // keyboard gets out of the way as soon as the results are touched.
    return Listener(
      onPointerDown: (_) => closeKeyboard(),
      // With the keyboard up, the tiles behind it must stay out of the pad's
      // reach: focus would otherwise walk onto a card nobody can see.
      child: ExcludeFocus(
        excluding: _keyboardOpen,
        child: Scrollbar(
          controller: _gridController,
          thumbVisibility: false,
          thickness: touchScreen ? 8 : 4,
          radius: const Radius.circular(4),
          child: GridView.builder(
            key: ValueKey(widget.revealed),
            controller: _gridController,
            // The games shelf draws portrait covers — a taller cell, so the
            // art keeps its 2:3 shape instead of shrinking into an icon slot.
            // Tile height covers the card's fixed slots (12 pad + 1 border +
            // 52 icon + 8 gap + 30 label + 1 border + 8 pad = 112) plus 2 px
            // of slack, so rows sit on an even rhythm instead of drifting
            // apart.
            gridDelegate: apps.view == AppsView.games
                ? const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 156,
                    mainAxisExtent: 260,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  )
                : const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 104,
                    mainAxisExtent: 114,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
            itemCount: visible.length,
            itemBuilder: (context, index) => apps.view == AppsView.games
                ? GameCard(
                    app: visible[index],
                    enterDelay:
                        widget.revealed ? _entrance.nextDelay() : null,
                    focusNode: _cardNode(index),
                  )
                : AppCard(
                    app: visible[index],
                    enterDelay:
                        widget.revealed ? _entrance.nextDelay() : null,
                    focusNode: _cardNode(index),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading(AppColors c) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: c.accent,
            ),
          ),
          const SizedBox(height: 14),
          Text('正在扫描已安装的应用…',
              style: TextStyle(fontSize: 12.5, color: c.textMuted)),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppColors c, AppsProvider apps) {
    final searching = apps.query.trim().isNotEmpty;
    // Search spans the whole catalog, so a failed search gets one message
    // whatever tab is active.
    final (icon, hint) = searching
        ? (Icons.search_off, '没有找到匹配的应用,试试关键词或首字母')
        : apps.activeCategory != null
            ? (
                Icons.filter_alt_off_outlined,
                '这个分类下暂时没有应用,换个分类或回到全部'
              )
            : switch (apps.view) {
                AppsView.recommended => (
                    Icons.insights_outlined,
                    '启动过的应用会按使用频率出现在这里'
                  ),
                AppsView.games => (
                    Icons.sports_esports_outlined,
                    '未检测到 Steam,或这台机器上还没有已安装的游戏'
                  ),
                AppsView.desktop => (
                    Icons.desktop_windows_outlined,
                    '桌面上还没有快捷方式'
                  ),
              };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: c.textMuted),
          const SizedBox(height: 12),
          Text(hint, style: TextStyle(fontSize: 13, color: c.textMuted)),
        ],
      ),
    );
  }
}
