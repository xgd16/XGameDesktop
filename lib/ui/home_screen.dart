import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../native/gamepad.dart';
import '../native/hwprobe_service.dart';
import '../native/window_shell.dart';
import '../state/app_activity.dart';
import '../state/wallpaper_gate.dart';
import '../state/apps_provider.dart';
import '../state/metrics_provider.dart';
import '../state/settings_provider.dart';
import '../state/weather_provider.dart';
import 'apps_pane.dart';
import 'background_layer.dart';
import 'boot_splash.dart';
import 'metrics_page.dart';
import 'metrics_panel.dart';
import 'nav.dart';
import 'pad_hints.dart';
import 'settings_page.dart';
import 'stats_page.dart';
import 'title_bar.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.bootScreen = true});

  /// Whether the window opens on the boot screen, which covers the shell until
  /// the catalog, the search index and the app icons have had their head start.
  /// False for tests that drive the shell itself: the boot screen holds the
  /// pad's input until the load is done, and those tests load nothing.
  final bool bootScreen;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    // Three pages, three controllers: the settings page's, the statistics
    // page's and the monitoring page's, each mounted only while it is open or
    // animating.
    with TickerProviderStateMixin {
  AppLifecycleListener? _lifecycle;

  /// The boot screen covers the shell from the first frame.
  late bool _bootVisible = widget.bootScreen;

  /// True once the field has split — the shell is on its own, and the grid's
  /// entrance wave runs under the pieces as they leave.
  late bool _bootRevealed = !widget.bootScreen;

  /// The user pressed something while the boot screen was up: stop waiting for
  /// whatever has not landed yet and hand the window over.
  bool _bootSkipped = false;

  /// The icon pass and the scan are capped: past these the window is handed
  /// over with whatever is ready, and the rest streams in behind the shell the
  /// way it always has. A cold first run extracts every icon in the catalog,
  /// which is not something a launcher should stand in front of.
  bool _bootIconsGivenUp = false;
  bool _bootCapped = false;
  Timer? _bootIconTimer;
  Timer? _bootCapTimer;
  static const _iconWait = Duration(milliseconds: 2400);
  static const _scanCap = Duration(seconds: 6);

  /// Drives the settings page over the body. The page stays mounted only while
  /// it is open or animating, so the grid underneath survives the trip and
  /// comes back exactly as it was.
  late final AnimationController _settingsCtrl = AnimationController(
    vsync: this,
    duration: Motion.base,
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _settingsAnim =
      CurvedAnimation(parent: _settingsCtrl, curve: Motion.outCubic);
  bool _settingsMounted = false;

  /// The settings page's focus scope. The shell owns it so it can hand the
  /// pad's highlight to the page the moment it opens — otherwise the
  /// highlight stays on whatever is behind the page, invisible, and an A
  /// press would land on it.
  ///
  /// The page walks in reading order and stops at its ends: wrapping would
  /// take the highlight from the last control back to a control above the
  /// page's scroll viewport, where nobody can see it.
  final FocusScopeNode _settingsFocus = FocusScopeNode(
    debugLabel: 'settings',
    traversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );

  /// Drives the statistics page, on the settings page's terms: mounted only
  /// while it is open or animating, so the grid underneath survives the trip.
  late final AnimationController _statsCtrl = AnimationController(
    vsync: this,
    duration: Motion.base,
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _statsAnim =
      CurvedAnimation(parent: _statsCtrl, curve: Motion.outCubic);
  bool _statsMounted = false;

  /// The statistics page's focus scope, arranged like the settings page's.
  final FocusScopeNode _statsFocus = FocusScopeNode(
    debugLabel: 'stats',
    traversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );

  /// Drives the monitoring page, on the same terms: mounted only while it is
  /// open or animating, so the recorder behind it is never rebuilt for a page
  /// nobody is looking at.
  late final AnimationController _metricsCtrl = AnimationController(
    vsync: this,
    duration: Motion.base,
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _metricsAnim =
      CurvedAnimation(parent: _metricsCtrl, curve: Motion.outCubic);
  bool _metricsMounted = false;

  /// The monitoring page's focus scope, arranged like the other two.
  final FocusScopeNode _metricsFocus = FocusScopeNode(
    debugLabel: 'metrics',
    traversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );

  /// Whether a full-screen page covers the shell. The three are mutually
  /// exclusive — opening one puts the others away — so this, rather than any
  /// single flag, is what the keyboard, the pad and the occlusion gate ask for.
  bool get _pageOpen =>
      _settingsMounted || _statsMounted || _metricsMounted;

  /// The shell's own focus. Keys bubble up here from whatever is inside, and
  /// entering immersive re-requests it so a focused search field lets go
  /// without leaving the window without a focus target.
  final FocusNode _rootFocus = FocusNode(debugLabel: 'home');

  /// The app grid, so the pad can put the highlight on the first tile when
  /// nothing of the page is focused yet.
  final _appsKey = GlobalKey<AppsPaneState>();

  /// The bar and the telemetry column, kept alive across the immersive swap.
  ///
  /// Entering or leaving immersive swaps the widget *above* the shell, and the
  /// framework therefore rebuilds everything the shell holds — the search
  /// field's pane survives because it is asked for by key, and without the
  /// same treatment the bar and the panel came back as fresh widgets: their
  /// focus nodes died with the old ones and the pad's highlight fell back to
  /// whatever the scope remembered, which for a bar button means the ring
  /// simply vanished. Keyed, they are moved across the swap instead of being
  /// rebuilt, so the highlight, the panel's scroll, and the entrance
  /// animations all stay where they were.
  final _barKey = GlobalKey(debugLabel: 'titleBar');
  final _panelKey = GlobalKey(debugLabel: 'metricsPanel');

  /// True while the window is in immersive fullscreen. The page itself does
  /// not change — it is the same shell, magnified to fill the screen.
  bool _immersive = false;

  StreamSubscription<GamepadAction>? _padSub;
  Timer? _padHintsTimer;
  bool _padHints = false;
  bool _keyboardOpen = false;

  /// The two providers this screen listens to directly rather than through the
  /// tree: the hardware probe (for whether the machine is a handheld) and the
  /// settings (for what kind of wallpaper is behind the settings page).
  HwprobeService? _hwprobe;
  SettingsProvider? _settings;

  /// The device history recorder. The shell is the only layer that holds both
  /// the probe and the settings, which is what it needs: what to read comes
  /// from the first, how often from the second.
  MetricsProvider? _metrics;

  /// The last control the pad's highlight rested on and the grid slot it sat
  /// in — what putting it back means (see [_healHighlight]).
  FocusNode? _lastHighlight;
  int? _lastHighlightSlot;

  @override
  void initState() {
    super.initState();
    if (widget.bootScreen) {
      _bootIconTimer = Timer(_iconWait, () {
        if (mounted) setState(() => _bootIconsGivenUp = true);
      });
      _bootCapTimer = Timer(_scanCap, () {
        if (mounted) setState(() => _bootCapped = true);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      WindowShell.ensureInitialized();
      final settings = context.read<SettingsProvider>();
      context.read<HwprobeService>().start();
      context.read<AppsProvider>().load();
      context.read<WeatherProvider>().start();
      context.read<GamepadService>().start();
      // The fullscreen probe belongs to the shell, and it now earns its two
      // seconds of window-manager calls even with a still picture behind the UI:
      // its verdict is what stands the telemetry's eased readouts down while a
      // game covers the launcher, so the panel is not rendering at vsync for
      // nobody. The shell is a consumer in its own right (ensure), and the live
      // wallpapers register themselves — a wallpaper adopted later starts its
      // own listeners.
      await settings.load();
      // The load above is the one await in here: if the shell went away while
      // it ran, its dispose has already released the gate, and starting the
      // probe now would arm a timer nobody owns.
      if (!mounted) return;
      WallpaperGate.start();
      WallpaperGate.ensure();
      // The usage-sampling choice goes straight into the backend's global
      // state — the header documents setting it before or during init — so
      // applying it here lands even while the worker isolate still probes.
      context.read<HwprobeService>().setUsageMode(settings.usageSensorMode);
      // The device history starts here, and only here: what to record is the
      // probe's readings, and how often is a setting that has just been read.
      _metrics
        ?..attach(MetricsProvider.probeSource(context.read<HwprobeService>()))
        ..start(
            interval: Duration(seconds: settings.sampleIntervalSeconds));
      if (settings.immersiveOnLaunch) _enterImmersive();
    });
    _padSub = context.read<GamepadService>().actions.listen(_onGamepadAction);
    // Whether this machine is a handheld is a fact about the hardware, and the
    // probe is where facts live — the settings own the verdict that reads it
    // (see SettingsProvider.lowPowerOn).
    _hwprobe = context.read<HwprobeService>()..addListener(_syncHandheld);
    // And the occlusion verdict follows the wallpaper kind: the settings page
    // draws a video wallpaper in its own preview card, so a video keeps playing
    // behind the page while a scene or a page stands down.
    _settings = context.read<SettingsProvider>()
      ..addListener(_syncOcclusion)
      // The collection rate is a setting, so the recorder hears about it here
      // rather than the settings page reaching across for a provider it has no
      // other business with.
      ..addListener(_syncSampleInterval);
    _metrics = context.read<MetricsProvider>();
    FocusManager.instance.addListener(_watchHighlight);
    FocusManager.instance.addListener(_onFocusMoved);
    _lifecycle = AppLifecycleListener(
      // Minimized or hidden: everything that keeps burning frames — the pad
      // poll, the video wallpaper, the telemetry timer, the clock tick — is
      // told to stand down, and told again when the window is back.
      onStateChange: AppActivity.update,
      onExitRequested: () async {
        // Quitting while immersive has to hand the taskbar its background
        // back — the accent would otherwise outlive the process.
        if (_immersive) WindowShell.setImmersive(false);
        // Flush the native poller and any debounced setting before the process
        // goes away.
        context.read<SettingsProvider>().saveNow();
        await context.read<HwprobeService>().shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  /// Keeps the recorder's rate in step with the setting. Cheap enough for the
  /// settings' own notify-per-slider-move: one int compare, and the recorder
  /// ignores a rate that has not moved.
  void _syncSampleInterval() {
    final settings = _settings;
    final metrics = _metrics;
    if (settings == null || metrics == null) return;
    metrics.setInterval(Duration(seconds: settings.sampleIntervalSeconds));
  }

  void _openSettings() {
    // Only one page can own the window: opening this one puts the others away,
    // and the layer order keeps the incoming page on top while the outgoing one
    // animates out.
    _closeStats();
    _closeMetrics();
    // The page covers the keyboard, so the keyboard gets out of the way: a
    // down press would otherwise walk the highlight onto keys nobody can see.
    _appsKey.currentState?.closeKeyboard();
    setState(() => _settingsMounted = true);
    // …and it covers the wallpaper too: nothing live behind it is visible from
    // here on (see [_syncOcclusion]).
    _syncOcclusion();
    _settingsCtrl.forward();
    // The page takes the highlight once it is laid out: from inside it the
    // pad walks its controls, and closing it hands the highlight back to
    // whatever had it before.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _settingsMounted) _settingsFocus.requestFocus();
    });
  }

  void _closeSettings() {
    if (!_settingsMounted) return;
    _settingsCtrl.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() => _settingsMounted = false);
      _syncOcclusion();
    });
  }

  void _openStats() {
    _closeSettings();
    _closeMetrics();
    _appsKey.currentState?.closeKeyboard();
    setState(() => _statsMounted = true);
    _syncOcclusion();
    _statsCtrl.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _statsMounted) _statsFocus.requestFocus();
    });
  }

  void _closeStats() {
    if (!_statsMounted) return;
    _statsCtrl.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() => _statsMounted = false);
      _syncOcclusion();
    });
  }

  void _openMetrics() {
    _closeSettings();
    _closeStats();
    _appsKey.currentState?.closeKeyboard();
    setState(() => _metricsMounted = true);
    _syncOcclusion();
    _metricsCtrl.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _metricsMounted) _metricsFocus.requestFocus();
    });
  }

  void _closeMetrics() {
    if (!_metricsMounted) return;
    _metricsCtrl.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() => _metricsMounted = false);
      _syncOcclusion();
    });
  }

  /// Puts whichever page is up away — the pad's X and a fresh search both want
  /// the shell to themselves.
  void _closePages() {
    _closeSettings();
    _closeStats();
    _closeMetrics();
  }

  /// Tells the settings whether this machine has a battery — the fact the
  /// low-power profile's "auto" reads. Idempotent, so the probe's 1 Hz tick
  /// costs one bool compare.
  void _syncHandheld() => _settings?.setHandheld(_hwprobe!.hasBattery);

  /// Every page paints the whole client area, so a live wallpaper behind them
  /// is drawing for nobody. The one exception is the settings page showing a
  /// video wallpaper in its own preview card — there the card draws the very
  /// session the wallpaper is. The statistics and monitoring pages show nothing
  /// of it, so a video stands down behind those like everything else.
  void _syncOcclusion() {
    final settings = _settings;
    if (settings == null) return;
    final previewedBySettings = _settingsMounted &&
        settings.backgroundSource == BackgroundSource.video;
    WallpaperGate.occlude(_pageOpen && !previewedBySettings);
  }

  void _toggleSettings() =>
      _settingsMounted ? _closeSettings() : _openSettings();

  void _toggleStats() => _statsMounted ? _closeStats() : _openStats();

  void _toggleMetrics() => _metricsMounted ? _closeMetrics() : _openMetrics();

  // ---- the boot screen ----
  //
  // The window opens on the boot screen and the shell loads behind it. The
  // load is weighted by what it costs: the scan first, then the search index,
  // then the icon pass, with the settings file ahead of them all (the palette
  // and the wallpaper are decided there, and showing the shell before that
  // would pop a wallpaper in behind the grid). Every phase reports itself, so
  // the hairline is progress, not a spinner dressed up as one.
  //
  // The reporting itself lives in [_BootLayer]: it watches both providers, and
  // the icon pass notifies every 100 ms — the shell underneath (the grid, its
  // sort, the wallpaper) must not rebuild at that rate.

  /// A key, a pad button or a click while the boot screen is up. Both the
  /// waiting and the assembly are cut short — the shell is usable, and its own
  /// progress reporting picks up whatever is still loading.
  void _skipBoot() {
    if (!_bootVisible || _bootSkipped) return;
    setState(() => _bootSkipped = true);
  }

  /// The field has started to split: the shell takes over, and the grid's wave
  /// runs as the pieces leave.
  void _onBootRevealed() {
    _bootIconTimer?.cancel();
    _bootIconTimer = null;
    _bootCapTimer?.cancel();
    _bootCapTimer = null;
    if (mounted) setState(() => _bootRevealed = true);
  }

  void _onBootFinished() {
    if (mounted) setState(() => _bootVisible = false);
  }

  void _enterImmersive() {
    if (_immersive) return;
    // The page comes down with the frame; the highlight stays where it is.
    // It used to be parked on the shell's own node, which is why the pad's
    // ring could vanish on the way in — and it is not needed: the shell's
    // node is an ancestor of everything, so F11 and Esc reach its key
    // handler from any focused widget, text field included.
    _closeSettings();
    setState(() => _immersive = true);
    // Best-effort: with no usable window handle the page still magnifies,
    // just inside the framed window.
    WindowShell.setImmersive(
      true,
      taskbarBlend: context.read<SettingsProvider>().immersiveTaskbarBlend,
      // The seam the window leaves at the bottom edge is painted in the
      // theme's backdrop color, so the transparent taskbar blends into it.
      backdropColor: AppColors.of(context).bg.toARGB32(),
    );
  }

  void _exitImmersive() {
    if (!_immersive) return;
    setState(() => _immersive = false);
    WindowShell.setImmersive(false);
  }

  void _toggleImmersive() => _immersive ? _exitImmersive() : _enterImmersive();

  /// F11 flips the mode from anywhere; Esc is the way out of fullscreen.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // The boot screen has the window, so a key is the user saying "enough" —
    // and a key that reaches the shell nobody can see would move a highlight or
    // open the keyboard behind it. F11 and Esc are the frame's own keys, not
    // the page's: they work at any time.
    if (_bootVisible &&
        key != LogicalKeyboardKey.f11 &&
        key != LogicalKeyboardKey.escape) {
      _skipBoot();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f11) {
      _toggleImmersive();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _immersive) {
      _exitImmersive();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- the pad ----
  //
  // Nothing below is pad-specific except the mapping: the directions move the
  // focus exactly like the arrow keys, A is Enter, B closes whatever is open —
  // soft keyboard, context menu, settings — and stops there. Leaving immersive
  // is the View button's job, so no stray B can throw the window out of
  // fullscreen, and X walks the highlight back to the tiles.

  void _onGamepadAction(GamepadAction action) {
    if (!mounted) return;
    // The boot screen has the window. A pad press is a user who does not want
    // to wait — but it must not reach the shell behind, where A on the first
    // tile launches an app nobody can see yet.
    if (_bootVisible) {
      _skipBoot();
      return;
    }
    // Rings belong to the pad and the keyboard. A pointer puts the framework
    // back on its own automatic rule (see the Listener in build).
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    // Even an action that leaves the highlight where it is (A on the tile it
    // already sits on) is the pad driving: the pointer's hover stops counting.
    HoverGate.drop();
    _showPadHints();
    switch (action) {
      case GamepadAction.up:
        _moveFocus(TraversalDirection.up);
      case GamepadAction.down:
        _moveFocus(TraversalDirection.down);
      case GamepadAction.left:
        _moveFocus(TraversalDirection.left);
      case GamepadAction.right:
        _moveFocus(TraversalDirection.right);
      case GamepadAction.accept:
        _accept();
      case GamepadAction.back:
        _back();
      case GamepadAction.search:
        _openSearch();
      case GamepadAction.grid:
        _focusAppsGrid();
      case GamepadAction.immersive:
        _toggleImmersive();
      case GamepadAction.menu:
        // On a tile the button is that tile's context menu — the pad's way to
        // pin, unpin or reach the file's folder. Anywhere else it is settings.
        if (!(_appsKey.currentState?.showFocusedCardMenu() ?? false)) {
          _toggleSettings();
        }
      case GamepadAction.tabPrev:
        _switchView(-1);
      case GamepadAction.tabNext:
        _switchView(1);
      case GamepadAction.pageUp:
        _page(TraversalDirection.up);
      case GamepadAction.pageDown:
        _page(TraversalDirection.down);
    }
  }

  void _moveFocus(TraversalDirection direction) {
    final node = FocusManager.instance.primaryFocus;
    final context = node?.context;
    // Nothing of the page has the focus yet — boot, or just back from a page
    // that took it: the pad starts on the tiles. A widget that keeps its own
    // highlight (the menu, the telemetry panel) gets the first refusal.
    if (context == null || identical(node, _rootFocus)) {
      if (!_pageOpen) _appsKey.currentState?.focusFirst();
      return;
    }
    // The bar is a strip of its own across the top: a move down from one of
    // its controls means the page's first row. Left to the geometric walk it
    // landed on whatever happened to sit underneath the bar button — above the
    // telemetry column that is the panel's scroll area, whose only sign of
    // focus is the edge of the panel, so the ring read as lost. The settings
    // page keeps its own moves: its scope should never hand the focus to a
    // field behind it.
    if (!_pageOpen &&
        direction == TraversalDirection.down &&
        _inTitleBar(context)) {
      _appsKey.currentState?.focusSearch();
      return;
    }
    // While the soft keyboard is up the pad belongs to it. On the keys the
    // keyboard walks its own rows; anywhere else — the search field, a
    // toggle, the telemetry column — down hands the highlight to its first
    // key. Neither the window's geometry nor the framework's move history
    // decides this: both had the highlight landing back on the field or
    // jumping to the telemetry column instead of the keys.
    final pane = _appsKey.currentState;
    if (_keyboardOpen && pane != null) {
      if (pane.keyboardFocused) {
        Actions.maybeInvoke(context, FocusDirectionIntent(direction));
        return;
      }
      if (direction == TraversalDirection.down) {
        pane.focusKeyboard();
        return;
      }
    }
    if (Actions.maybeInvoke(context, FocusDirectionIntent(direction)) == true) {
      return;
    }
    // ignoreTextFields is what makes this work from the search field: the
    // field's own action swallows the default intent outright (it exists for
    // caret movement and moves nothing), and the stick means "leave the
    // field" — down reaches the tiles, or the soft keyboard's keys when it
    // is up. Physical arrow keys still go through the default intent and
    // keep moving the caret.
    Actions.maybeInvoke(
      context,
      DirectionalFocusIntent(direction, ignoreTextFields: false),
    );
  }

  /// Whether the pad's highlight is on one of the title bar's own controls.
  /// Asked of the element tree rather than of the geometry: in immersive mode
  /// the whole shell is scaled, so a rect cannot be compared against the bar's
  /// height, but the ancestry is the same at any zoom.
  static bool _inTitleBar(BuildContext context) {
    var inside = false;
    context.visitAncestorElements((element) {
      if (element.widget is TitleBar) {
        inside = true;
        return false;
      }
      return true;
    });
    return inside;
  }

  /// Keeps track of where the highlight lives, and puts it back when the
  /// control that held it is taken away.
  ///
  /// Closing the settings page over a grid that changed under it, filtering
  /// the tile it sat on out of the list, a control the layout dropped: the
  /// focus falls back to the shell's own node or to nothing at all, and then
  /// no ring is drawn anywhere — the stick seems to do nothing, and start-up
  /// is the only state where that is honest (the pad has not been used yet).
  void _watchHighlight() {
    final node = FocusManager.instance.primaryFocus;
    if (node != null && node.parent != null && !identical(node, _rootFocus)) {
      _lastHighlight = node;
      _lastHighlightSlot = _appsKey.currentState?.focusedCardIndex;
      return;
    }
    if (!mounted || _lastHighlight == null) return;
    _lastHighlight = null;
    // A frame later: what took the node away may still be settling, and
    // something may claim the focus back in the meantime (the framework
    // restoring it to a control that survived).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = FocusManager.instance.primaryFocus;
      if (current != null &&
          current.parent != null &&
          !identical(current, _rootFocus)) {
        return;
      }
      _healHighlight();
    });
  }

  /// Puts the highlight back on the grid — the slot it sat in when that slot
  /// still exists, the first tile otherwise, the search field when the view
  /// came up empty.
  void _healHighlight() {
    final pane = _appsKey.currentState;
    if (pane == null) return;
    // With a page open the highlight belongs to the page; it draws the whole
    // window, so there is nothing invisible about it.
    if (_pageOpen) return;
    if (_keyboardOpen) {
      pane.focusKeyboard();
      return;
    }
    final slot = _lastHighlightSlot;
    if (slot != null) {
      pane.restoreGridFocus(slot);
      return;
    }
    pane.focusFirst();
  }

  void _accept() {
    final node = FocusManager.instance.primaryFocus;
    final context = node?.context;
    if (context == null || identical(node, _rootFocus)) {
      if (!_pageOpen) _appsKey.currentState?.focusFirst();
      return;
    }
    Actions.maybeInvoke(context, const ActivateIntent());
  }

  void _back() {
    // Whatever has the focus goes first: the soft keyboard, a context menu.
    // Only an action that answers `true` counts as having taken the key — the
    // route under everything registers a DismissIntent of its own that would
    // otherwise swallow every press of B.
    final context = FocusManager.instance.primaryFocus?.context;
    if (context != null &&
        Actions.maybeInvoke(context, const DismissIntent()) == true) {
      return;
    }
    // The keyboard can be up while the focus sits on the search field — which
    // has no DismissIntent of its own, and whose context never reaches the
    // keyboard's actions. B is still the key that puts it away.
    if (_keyboardOpen) {
      _appsKey.currentState?.closeKeyboard();
      return;
    }
    _closePages();
    // Deliberately no immersive here: B at the top level does nothing, the
    // way a console's B does at its home screen. Leaving fullscreen is the
    // View button's job and must not be one careless press away.
  }

  /// X is the way back to the launcher's home from wherever the highlight
  /// wandered — the telemetry panel, the search field, behind the soft
  /// keyboard. It clears the settings page out of the way first, then hands
  /// the highlight to the first tile; focusFirst puts the keyboard away.
  void _focusAppsGrid() {
    _closePages();
    _appsKey.currentState?.focusFirst();
  }

  void _openSearch() {
    _closePages();
    _appsKey.currentState?.openKeyboard();
  }

  /// LB/RB walk the views of the grid, the way a library's tabs do — only the
  /// ones that exist: a machine without Steam skips the games shelf. The view
  /// that comes up can be shorter than the slot the highlight is on, so the
  /// highlight is aimed again once the new grid has been laid out.
  void _switchView(int delta) {
    final apps = context.read<AppsProvider>();
    final views = apps.availableViews;
    final at = views.indexOf(apps.view);
    final next = (at + delta) % views.length;
    final slot = _appsKey.currentState?.focusedCardIndex;
    apps.setView(views[next < 0 ? next + views.length : next]);
    if (slot != null) _appsKey.currentState?.restoreGridFocus(slot);
  }

  /// LT/RT page through whatever the focus is sitting in — the tile grid or
  /// the telemetry panel.
  void _page(TraversalDirection direction) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return;
    Actions.maybeInvoke(
      context,
      ScrollIntent(
        direction: direction == TraversalDirection.up
            ? AxisDirection.up
            : AxisDirection.down,
        type: ScrollIncrementType.page,
      ),
    );
  }

  /// The highlight the last time it moved, so [FocusManager]'s other reason
  /// for notifying — a highlight-mode change, which the pointer itself causes
  /// — can be told apart from the highlight actually moving.
  FocusNode? _lastFocus;

  /// The highlight moved: the pad or the keyboard is steering, or a page just
  /// took it. The hover fill left under a parked mouse would read as a second
  /// selection, so it goes — see [HoverGate]. A focus *move* only: the pointer
  /// moving or clicking must not blow out the hover it is standing in.
  void _onFocusMoved() {
    final node = FocusManager.instance.primaryFocus;
    if (identical(node, _lastFocus)) return;
    _lastFocus = node;
    HoverGate.drop();
  }

  void _showPadHints() {
    if (!_padHints) setState(() => _padHints = true);
    _padHintsTimer?.cancel();
    _padHintsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _padHints = false);
    });
  }

  void _resetHighlightStrategy(PointerDownEvent event) {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_watchHighlight);
    FocusManager.instance.removeListener(_onFocusMoved);
    _hwprobe?.removeListener(_syncHandheld);
    _settings?.removeListener(_syncOcclusion);
    _settings?.removeListener(_syncSampleInterval);
    // The shell's demand for the gate's verdict goes with it, and so does the
    // probe's timer (the live surfaces release theirs through the widgets that
    // draw them, which are being unmounted right now).
    WallpaperGate.release();
    _padSub?.cancel();
    _padHintsTimer?.cancel();
    _bootIconTimer?.cancel();
    _bootCapTimer?.cancel();
    _lifecycle?.dispose();
    _settingsCtrl.dispose();
    _settingsFocus.dispose();
    _statsCtrl.dispose();
    _statsFocus.dispose();
    _metricsCtrl.dispose();
    _metricsFocus.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // One field, not the whole provider: this build also holds the grid, and
    // the settings notify on every slider move.
    final hasBackground = context.select<SettingsProvider, bool>(
        (settings) => settings.hasBackground);
    final shell = _buildShell(c);
    // Blended immersive runs the window under the taskbar, and the bar stays
    // on top of it — transparent, but its buttons are still there. The hints
    // float on the window itself rather than on the shell, so they can climb
    // the bar's height here; the inset comes back in physical pixels.
    final taskbarInset = _immersive
        ? WindowShell.bottomInset / MediaQuery.devicePixelRatioOf(context)
        : 0.0;
    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      // The shell spans the whole window, so as a traversal candidate this
      // node sits inside every directional "band" and would win moves that
      // have no closer stop, yanking the highlight to nowhere. Out of the
      // traversal order it goes; the pad's own identical(node, _rootFocus)
      // checks still land here, and direct requestFocus works as before.
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: c.bg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // The wallpaper sits under everything, title bar included; the
            // theme color shows wherever it does not reach.
            if (hasBackground) const AppBackground(),
            // Immersive is not a second page: it is this one, magnified. The
            // same shell stays mounted, so nothing is lost going in or out.
            Listener(
              // A pointer means the highlight rings go away again: they exist
              // for the pad and the keyboard, not for a mouse.
              behavior: HitTestBehavior.translucent,
              onPointerDown: _resetHighlightStrategy,
              child: _immersive
                  ? _Magnified(key: const Key('immersiveZoom'), child: shell)
                  : shell,
            ),
            // The pad's cheat sheet, outside the magnifier so it reads the
            // same at any zoom. It is a blurred card that slides in over the
            // grid; the boundary keeps that animation from re-recording the
            // shell and the wallpaper with it.
            Positioned(
              left: 0,
              right: 0,
              bottom: 14 + taskbarInset,
              child: Center(
                child: RepaintBoundary(
                  child: PadHints(visible: _padHints && !_keyboardOpen),
                ),
              ),
            ),
            // Last, so it covers the shell, the wallpaper and the hints alike.
            // It comes off the tree once its field has left, and the shell
            // underneath has been loading the whole time.
            if (_bootVisible)
              _BootLayer(
                iconsGivenUp: _bootIconsGivenUp,
                capped: _bootCapped,
                skipped: _bootSkipped,
                onSkip: _skipBoot,
                onRevealed: _onBootRevealed,
                onFinished: _onBootFinished,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildShell(AppColors c) {
    return Column(
      children: [
        TitleBar(
          key: _barKey,
          onToggleSettings: _toggleSettings,
          onToggleStats: _toggleStats,
          onToggleMetrics: _toggleMetrics,
          onImmersive: _toggleImmersive,
          immersive: _immersive,
          settingsOpen: _settingsMounted,
          statsOpen: _statsMounted,
          metricsOpen: _metricsMounted,
        ),
        Expanded(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: AppsPane(
                        key: _appsKey,
                        revealed: _bootRevealed,
                        onKeyboardChanged: (open) {
                          if (_keyboardOpen != open) {
                            setState(() => _keyboardOpen = open);
                          }
                        },
                      ),
                    ),
                    Container(width: 1, color: c.border),
                    // The telemetry panel repaints on every 1 Hz reading; the
                    // boundary keeps that raster work inside the panel's own
                    // layer instead of re-recording the whole window.
                    RepaintBoundary(
                      key: _panelKey,
                      child: const MetricsPanel(),
                    ),
                  ],
                ),
                if (_settingsMounted)
                  FadeTransition(
                    opacity: _settingsAnim,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(_settingsAnim),
                      child: SettingsPage(
                        onClose: _closeSettings,
                        onEnterImmersive: _enterImmersive,
                        focusNode: _settingsFocus,
                        gamepad: context.watch<GamepadService>(),
                        hwprobe: context.read<HwprobeService>(),
                      ),
                    ),
                  ),
                // Last, so each page covers the one animating out underneath it:
                // the statistics page above the settings page, the monitoring
                // page above both.
                if (_statsMounted)
                  FadeTransition(
                    opacity: _statsAnim,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(_statsAnim),
                      child: StatsPage(
                        onClose: _closeStats,
                        focusNode: _statsFocus,
                      ),
                    ),
                  ),
                if (_metricsMounted)
                  FadeTransition(
                    opacity: _metricsAnim,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(_metricsAnim),
                      child: MetricsPage(
                        onClose: _closeMetrics,
                        focusNode: _metricsFocus,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The boot screen plus the load reporting it draws.
///
/// It exists as a widget of its own so the reporting can watch the providers
/// without rebuilding the shell: the icon pass notifies every 100 ms, the index
/// build every ~8 ms, and the grid, its sort and the wallpaper all sit in the
/// shell *below* this — rebuilding them at that rate is what made the opening
/// seconds stutter.
class _BootLayer extends StatelessWidget {
  const _BootLayer({
    required this.iconsGivenUp,
    required this.capped,
    required this.skipped,
    required this.onSkip,
    required this.onRevealed,
    required this.onFinished,
  });

  /// The icon pass stopped being waited on (the wait ran out).
  final bool iconsGivenUp;

  /// The scan ran out of its own budget; the shell takes over with what it has.
  final bool capped;

  final bool skipped;
  final VoidCallback onSkip;
  final VoidCallback onRevealed;
  final VoidCallback onFinished;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final apps = context.watch<AppsProvider>();

    var progress = 0.0;
    if (settings.applied) progress += 0.06;
    final scanned = apps.status == AppsStatus.ready;
    if (scanned) progress += 0.44;
    if (apps.searchIndexReady) progress += 0.22;
    progress += 0.28 * apps.iconProgress;

    final iconsDone = apps.iconProgress >= 0.995 || iconsGivenUp;
    final ready = capped ||
        (settings.applied && scanned && apps.searchIndexReady && iconsDone);

    // The shell's own words for the same work — the search field behind this
    // screen carries the index line verbatim.
    final String label;
    if (!settings.applied) {
      label = '正在启动…';
    } else if (!scanned) {
      label = '正在扫描已安装的应用…';
    } else if (!apps.searchIndexReady) {
      label = apps.preparation?.label ?? '正在准备应用列表…';
    } else if (!iconsDone) {
      label = '正在读取应用图标 ${apps.iconsDone}/${apps.iconsTotal}';
    } else {
      label = '就绪';
    }

    return BootSplash(
      progress: progress,
      label: label,
      ready: ready,
      skipped: skipped,
      onSkip: onSkip,
      onRevealed: onRevealed,
      onFinished: onFinished,
    );
  }
}

/// Immersive mode is the desktop page, closer: the shell lays out for a
/// [_nominalWidth]-wide window and is scaled up to the real screen, so it
/// keeps the arrangement it has in a window and simply reads bigger — a 4K
/// display gets the same page at 2×, not twice the tiles.
class _Magnified extends StatelessWidget {
  const _Magnified({super.key, required this.child});

  final Widget child;

  /// The layout width the shell is drawn for; the screen width over this is
  /// the magnification.
  static const double _nominalWidth = 1600;

  /// The runner refuses to shrink a window below this; letting the layout fall
  /// under it would break the rows that minimum exists to protect.
  static const Size _minShell = Size(1180, 760);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final byDisplay = math.max(1.0, w / _nominalWidth);
        final byMinimum =
            math.max(1.0, math.min(w / _minShell.width, h / _minShell.height));
        final zoom = math.min(byDisplay, byMinimum);
        if (zoom <= 1.001) return child;
        final size = Size(w / zoom, h / zoom);
        // FittedBox owns the box the screen sees — the scaled painting and the
        // hit testing both cover every pixel, which a Transform alone would
        // not: its box stays at the smaller laid-out size.
        return FittedBox(
          fit: BoxFit.fill,
          child: SizedBox.fromSize(
            size: size,
            // Anything measuring itself against the window (the context menu)
            // has to see the laid-out size, not the screen's.
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(size: size),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
