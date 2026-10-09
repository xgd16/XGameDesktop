import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../state/app_activity.dart';
import 'window_shell.dart';

/// What a pad press means in this app's own vocabulary — the same things the
/// keyboard already does (arrows, Enter, Esc, F11), plus the ones a couch
/// needs that no key has: search, the tile grid, and settings.
enum GamepadAction {
  up,
  down,
  left,
  right,
  accept,
  back,
  search,

  /// The launcher's home: the highlight goes back to the app tiles. Lives on
  /// X because a stray press of it only moves the focus — a mode toggle like
  /// immersive was too easy to hit by accident on a face button.
  grid,
  immersive,
  menu,
  tabPrev,
  tabNext,
  pageUp,
  pageDown,
}

/// One reading of a pad, normalized: sticks in -1..1 (up is positive, the way
/// XInput reports them), triggers in 0..255, buttons as the raw
/// XINPUT_GAMEPAD bitmask.
@immutable
class GamepadReading {
  const GamepadReading({
    this.buttons = 0,
    this.thumbLX = 0,
    this.thumbLY = 0,
    this.leftTrigger = 0,
    this.rightTrigger = 0,
  });

  final int buttons;
  final double thumbLX;
  final double thumbLY;
  final int leftTrigger;
  final int rightTrigger;
}

/// Reads the pad in [slot] (0..3), or null when that slot has none. Swapped
/// out in tests; the real one is XInput.
typedef GamepadSampler = GamepadReading? Function(int slot);

/// Whether the app is the window in front. Swapped out in tests; the real one
/// asks Windows for the foreground window.
typedef ForegroundCheck = bool Function();

bool _appIsForeground() => WindowShell.isForeground;

// ---- XINPUT_GAMEPAD buttons ----
const _dpadUp = 0x0001;
const _dpadDown = 0x0002;
const _dpadLeft = 0x0004;
const _dpadRight = 0x0008;
const _start = 0x0010;
const _backButton = 0x0020;
const _leftShoulder = 0x0100;
const _rightShoulder = 0x0200;
const _buttonA = 0x1000;
const _buttonB = 0x2000;
const _buttonX = 0x4000;
const _buttonY = 0x8000;

/// XINPUT_GAMEPAD_TRIGGER_THRESHOLD: below this a trigger is just resting.
const _triggerThreshold = 30;

/// Sticks rest near zero but rarely at it; 7849 is the XInput deadzone.
const _stickDeadzone = 7849 / 32767;

/// First repeat while a direction is held, then the interval after it. Long
/// enough that a single tap is one step, short enough to cross a long list.
const _repeatDelay = Duration(milliseconds: 380);
const _repeatInterval = Duration(milliseconds: 90);
const _triggerRepeatDelay = Duration(milliseconds: 420);
const _triggerRepeatInterval = Duration(milliseconds: 130);

/// Polls an Xbox-style pad and turns it into [GamepadAction]s.
///
/// XInput is pull-only — there is no callback to wait on — so this is a timer:
/// ~16 ms while the window is in front with a pad connected, a lazy 250 ms
/// otherwise, which keeps both hot-plugging and the window coming back to the
/// front working without burning frames on a machine that has neither.
///
/// The loop only acts while the window is visible *and* in front. The OS
/// routes keyboard events to the focused window, but nothing routes the pad:
/// a press while another window is in front belongs to that window (usually
/// the game this launcher just started), so acting on it here would steer two
/// apps at once.
class GamepadService extends ChangeNotifier {
  GamepadService({
    GamepadSampler? sampler,
    ForegroundCheck? foreground,
    this.activeInterval = const Duration(milliseconds: 16),
    this.idleInterval = const Duration(milliseconds: 250),
  })  : _sampler = sampler ?? XInput.sampler,
        _foreground = foreground ?? _appIsForeground;

  final GamepadSampler _sampler;

  /// Whether the app is the window in front. Asked at the top of every poll:
  /// the window can change under us between one tick and the next, and unlike
  /// the keyboard — which Windows routes to the focused window — nothing
  /// tells us where the pad's presses are headed.
  final ForegroundCheck _foreground;

  /// How often the pad is read while one is connected, and how often the
  /// ports are probed while none is.
  final Duration activeInterval;
  final Duration idleInterval;

  /// Test seam: the clock the repeat timers read.
  DateTime Function() clock = DateTime.now;

  final _actions = StreamController<GamepadAction>.broadcast();

  Timer? _timer;
  bool _running = false;
  int _slot = -1;

  /// Direction currently pushed on the stick, if any — the stick is read as a
  /// single direction (dominant axis) so a wobbling diagonal does not fire two
  /// steps at once.
  GamepadAction? _stickDir;

  /// When each repeating action is due to fire again.
  final Map<GamepadAction, DateTime> _nextRepeat = {};

  /// Which edge-triggered actions were held on the previous poll.
  final Map<GamepadAction, bool> _wasHeld = {};

  bool get connected => _slot >= 0;

  /// Everything the pad asks for, in press order.
  Stream<GamepadAction> get actions => _actions.stream;

  /// Whether XInput itself could be loaded. A false here on Windows means no
  /// pad can ever show up.
  bool get backendLoaded => XInput.loaded;

  void start() {
    if (_running) return;
    _running = true;
    AppActivity.visible.removeListener(_onActivity);
    AppActivity.visible.addListener(_onActivity);
    // Started while the window is hidden (a restart, say): park until it is
    // back, rather than polling for a window nobody can see. Started merely
    // unfocused, the loop still runs — on the lazy interval, as the probe
    // that notices the window coming back to the front.
    if (!AppActivity.isVisible) return;
    _poll();
    _schedule(_interval);
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _forget();
    AppActivity.visible.removeListener(_onActivity);
  }

  /// Whether the pad is ours to read right now. A visible window is not
  /// enough: whoever is in front owns the pad, so anything pressed while we
  /// are behind another window is meant for that window.
  bool get _shouldRun => AppActivity.isVisible && _foreground();

  /// The cadence for the next tick: the fast one only for a window that is in
  /// front with a pad attached. Everything else — no pad, no foreground — is
  /// a probe, and probes can afford to be lazy.
  Duration get _interval =>
      _shouldRun && _slot >= 0 ? activeInterval : idleInterval;

  /// The window went away or came back. Only [AppActivity.visible] needs a
  /// listener: coming back to the front is noticed by the poll loop itself,
  /// since Windows gives no reliable event for it (this runner's own window
  /// procedure swallows WM_ACTIVATE, and the lifecycle's `inactive` with it).
  void _onActivity() {
    if (!_running) return;
    if (!AppActivity.isVisible) {
      _timer?.cancel();
      _timer = null;
      _forget();
      return;
    }
    _poll();
    _schedule(_interval);
  }

  /// Drops whatever the pad was mid-doing, leaving the timer alone: after a
  /// pause the first real press must count as a press — a release nobody
  /// polled must not swallow it, and a repeat whose time has passed must not
  /// fire out of nowhere.
  void _forget() {
    _stickDir = null;
    _wasHeld.clear();
    _nextRepeat.clear();
  }

  void _schedule(Duration interval) {
    if (!_running || !AppActivity.isVisible) return;
    _timer = Timer(interval, () {
      _poll();
      _schedule(_interval);
    });
  }

  /// One poll: read the pad, fire what changed. Exposed for tests, which drive
  /// a fake sampler by hand instead of waiting on the timer.
  @visibleForTesting
  void pollOnce() => _poll();

  void _poll() {
    // Not ours right now (another window in front, or the window is hidden):
    // drop what was held and say nothing. The probe keeps running, so coming
    // back to the front needs no event from Windows.
    if (!_shouldRun) {
      _forget();
      return;
    }
    var reading = _slot >= 0 ? _sampler(_slot) : null;
    if (reading == null) {
      // Not connected (or just unplugged): look for one.
      for (var slot = 0; slot < 4; slot++) {
        final found = _sampler(slot);
        if (found != null) {
          _slot = slot;
          reading = found;
          _stickDir = null;
          _wasHeld.clear();
          _nextRepeat.clear();
          notifyListeners();
          break;
        }
      }
      if (reading == null) {
        if (_slot >= 0) {
          _slot = -1;
          _stickDir = null;
          _wasHeld.clear();
          _nextRepeat.clear();
          notifyListeners();
        }
        return;
      }
    }

    final now = clock();
    // The two sets are reused: this runs at 60 Hz while a pad is connected, and
    // two throwaway hash sets per tick is pure GC churn.
    final directions = _directions..clear();
    if (reading.buttons & _dpadUp != 0) directions.add(GamepadAction.up);
    if (reading.buttons & _dpadDown != 0) directions.add(GamepadAction.down);
    if (reading.buttons & _dpadLeft != 0) directions.add(GamepadAction.left);
    if (reading.buttons & _dpadRight != 0) directions.add(GamepadAction.right);
    _stickDir = _stickDirection(reading, _stickDir);
    if (_stickDir != null) directions.add(_stickDir!);

    // Directions repeat while held; everything else fires once per press.
    for (final action in directions) {
      final due = _nextRepeat[action];
      if (due == null) {
        _nextRepeat[action] = now.add(_repeatDelay);
        _emit(action);
      } else if (now.isAfter(due)) {
        _nextRepeat[action] = now.add(_repeatInterval);
        _emit(action);
      }
    }
    _nextRepeat.removeWhere((action, _) =>
        _isDirection(action) && !directions.contains(action));

    // The face cluster is navigation, so only harmless things live there: X
    // walks the highlight home and nothing more. Immersive sits on the View
    // button, off on its own where a thumb heading for A/B/X/Y never lands —
    // it used to share B's back job, which nothing misses.
    final edgeActions = _edgeActions..clear();
    if (reading.buttons & _buttonA != 0) edgeActions.add(GamepadAction.accept);
    if (reading.buttons & _buttonB != 0) edgeActions.add(GamepadAction.back);
    if (reading.buttons & _buttonY != 0) edgeActions.add(GamepadAction.search);
    if (reading.buttons & _buttonX != 0) edgeActions.add(GamepadAction.grid);
    if (reading.buttons & _backButton != 0) {
      edgeActions.add(GamepadAction.immersive);
    }
    if (reading.buttons & _start != 0) edgeActions.add(GamepadAction.menu);
    if (reading.buttons & _leftShoulder != 0) {
      edgeActions.add(GamepadAction.tabPrev);
    }
    if (reading.buttons & _rightShoulder != 0) {
      edgeActions.add(GamepadAction.tabNext);
    }
    if (reading.leftTrigger >= _triggerThreshold) {
      edgeActions.add(GamepadAction.pageUp);
    }
    if (reading.rightTrigger >= _triggerThreshold) {
      edgeActions.add(GamepadAction.pageDown);
    }
    for (final action in edgeActions) {
      final held = _wasHeld[action] ?? false;
      final repeats = action == GamepadAction.pageUp ||
          action == GamepadAction.pageDown;
      final due = _nextRepeat[action];
      if (!held) {
        _wasHeld[action] = true;
        if (repeats) _nextRepeat[action] = now.add(_triggerRepeatDelay);
        _emit(action);
      } else if (repeats && due != null && now.isAfter(due)) {
        _nextRepeat[action] = now.add(_triggerRepeatInterval);
        _emit(action);
      }
    }
    // Collected first: the map cannot be modified while its keys are iterated.
    _released.clear();
    for (final action in _wasHeld.keys) {
      if (!edgeActions.contains(action)) _released.add(action);
    }
    for (final action in _released) {
      _wasHeld.remove(action);
      _nextRepeat.remove(action);
    }
  }

  /// Per-poll scratch, reused so 60 Hz polling does not allocate.
  final Set<GamepadAction> _directions = <GamepadAction>{};
  final Set<GamepadAction> _edgeActions = <GamepadAction>{};
  final List<GamepadAction> _released = <GamepadAction>[];

  /// The stick as one of the four directions, with the current one sticky:
  /// a stick pushed into a corner wobbles between its two axes, and flipping
  /// on every wobble would read as an extra step. The direction already in
  /// hand keeps the lead while its own axis is still clearly pushed and still
  /// points the same way — pushing the stick the other way always lands.
  static GamepadAction? _stickDirection(
      GamepadReading reading, GamepadAction? current) {
    final x = reading.thumbLX;
    final y = reading.thumbLY;
    final ax = x.abs();
    final ay = y.abs();
    if (math.max(ax, ay) < _stickDeadzone) return null;
    final dominant = ax > ay
        ? (x > 0 ? GamepadAction.right : GamepadAction.left)
        : (y > 0 ? GamepadAction.up : GamepadAction.down);
    if (current == null || current == dominant) return dominant;
    final horizontal = current == GamepadAction.left ||
        current == GamepadAction.right;
    final currentAxis = horizontal ? ax : ay;
    final otherAxis = horizontal ? ay : ax;
    final sameSign = horizontal
        ? (current == GamepadAction.right) == (x > 0)
        : (current == GamepadAction.up) == (y > 0);
    if (sameSign &&
        currentAxis > _stickDeadzone * 0.5 &&
        otherAxis < currentAxis * 1.25) {
      return current;
    }
    return dominant;
  }

  static bool _isDirection(GamepadAction action) =>
      action == GamepadAction.up ||
      action == GamepadAction.down ||
      action == GamepadAction.left ||
      action == GamepadAction.right;

  void _emit(GamepadAction action) {
    if (!_actions.isClosed) _actions.add(action);
  }

  @override
  void dispose() {
    stop();
    _actions.close();
    super.dispose();
  }
}

// ---- XInput ----

final class _XInputGamepad extends Struct {
  @Uint16()
  external int buttons;
  @Uint8()
  external int leftTrigger;
  @Uint8()
  external int rightTrigger;
  @Int16()
  external int thumbLX;
  @Int16()
  external int thumbLY;
  @Int16()
  external int thumbRX;
  @Int16()
  external int thumbRY;
}

final class _XInputState extends Struct {
  @Uint32()
  external int packet;
  external _XInputGamepad pad;
}

typedef _GetStateNative = Uint32 Function(Uint32, Pointer<_XInputState>);
typedef _GetStateDart = int Function(int, Pointer<_XInputState>);

/// The real XInput binding. Hand-rolled like the rest of the native layer:
/// xinput1_4 is the Windows 8+ library; the older names are there for
/// completeness (a 9.1.0 pad still works, it just reports fewer buttons).
class XInput {
  XInput._();

  static bool _tried = false;
  static _GetStateDart? _getState;
  static Pointer<_XInputState>? _state;

  static bool get loaded => _getState != null;

  static GamepadReading? sampler(int slot) => read(slot);

  static GamepadReading? read(int slot) {
    if (!Platform.isWindows) return null;
    if (!_tried) _load();
    final getState = _getState;
    final state = _state;
    if (getState == null || state == null) return null;
    // 0 = connected, 1167 = ERROR_DEVICE_NOT_CONNECTED; anything else means
    // this slot has nothing to say.
    if (getState(slot, state) != 0) return null;
    final pad = state.ref.pad;
    return GamepadReading(
      buttons: pad.buttons,
      thumbLX: _axis(pad.thumbLX),
      thumbLY: _axis(pad.thumbLY),
      leftTrigger: pad.leftTrigger,
      rightTrigger: pad.rightTrigger,
    );
  }

  static double _axis(int value) => (value / 32767.0).clamp(-1.0, 1.0);

  static void _load() {
    _tried = true;
    for (final name in const [
      'xinput1_4.dll',
      'xinput1_3.dll',
      'xinput9_1_0.dll',
    ]) {
      try {
        final lib = DynamicLibrary.open(name);
        _getState = lib
            .lookupFunction<_GetStateNative, _GetStateDart>('XInputGetState');
        _state = calloc<_XInputState>();
        return;
      } catch (_) {
        // Try the next one.
      }
    }
  }
}
