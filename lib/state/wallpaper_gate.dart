import 'dart:async';

import 'package:flutter/foundation.dart';

import '../native/window_shell.dart';
import '../native/win32_api.dart';
import 'app_activity.dart';

/// Whether the live wallpapers may run right now.
///
/// [AppActivity] only knows about this window; a wallpaper has one more reason
/// to stop: another app — almost always a game — fullscreen over it. The
/// foreground window covering its own monitor means everything under it is
/// unseen, and a 60 fps scene nobody sees is the most expensive thing this app
/// does. This is Wallpaper Engine's own pause rule.
///
/// The verdict is one notifier ([allowed]) that folds both signals together —
/// hidden and covered are the same verdict to a wallpaper. The video sessions
/// pause their players on it, and the two WebView wallpapers suspend their
/// browsers; nothing else needs to know why.
///
/// Like every recurring job that costs real CPU, the fullscreen probe's timer
/// is started by the shell ([start]); a consumer that only [ensure]s the gate
/// still gets the visibility half of the verdict, and the fullscreen half
/// folds in once the shell has spoken.
class WallpaperGate {
  WallpaperGate._();

  /// False while the window is hidden or a fullscreen app owns the foreground.
  static final ValueNotifier<bool> allowed = ValueNotifier<bool>(true);

  /// Test seam: replaces the Win32 probe. Null asks Windows.
  static bool Function()? probeOverride;

  /// A probe per two seconds: a handful of window-manager calls, against a
  /// wallpaper that burns the GPU sixty times a second when it should not.
  static const _pollEvery = Duration(seconds: 2);

  static Timer? _timer;
  static bool _fullscreen = false;

  /// True while something *inside* the app covers the window — the settings
  /// page, which paints the whole client area. The window's own state does not
  /// change when a page comes up, so this is the only thing that can say the
  /// wallpaper behind it went out of sight.
  static bool _occluded = false;

  static bool _demanded = false;
  static bool _pollingEnabled = false;

  /// The shell's startup call: turns the fullscreen probing on and answers
  /// once right away. The timer itself waits for a consumer ([ensure]) — with
  /// no live surface on screen there is nothing to gate and nothing to probe
  /// for.
  static void start() {
    _pollingEnabled = true;
    _poll();
    _maybeStartPolling();
  }

  /// A consumer registers: it pauses and resumes on [allowed] from here on.
  /// Idempotent per process — demand, once there, stays; wallpapers switch
  /// underneath the listeners all the time.
  static void ensure() {
    if (_demanded) return;
    _demanded = true;
    AppActivity.visible.addListener(_onActivity);
    _update();
    _maybeStartPolling();
  }

  /// The shell's own overlay comes up: the settings page paints the whole
  /// window, so a wallpaper behind it is rendering for nobody. The shell knows
  /// which overlay it put up and — for the one kind of wallpaper it is still
  /// showing in there, a video playing in the page's own preview card — it
  /// simply does not call this.
  static void occlude(bool covered) {
    if (covered == _occluded) return;
    _occluded = covered;
    _update();
  }

  /// The shell lets go of its demand — it is being torn down. The probe's timer
  /// goes with it: the live surfaces release theirs through the widgets that
  /// draw them, and the shell is the one consumer whose lifetime is the whole
  /// window, so without this the timer would outlive the tree that asked for it
  /// (a widget test unmounts the shell and would be left holding a pending
  /// periodic timer).
  static void release() {
    if (!_demanded) return;
    _demanded = false;
    AppActivity.visible.removeListener(_onActivity);
    _timer?.cancel();
    _timer = null;
  }

  /// Both halves must agree before the probe earns its timer: the shell said
  /// there is a live wallpaper worth gating, and something actually consumes
  /// the verdict.
  static void _maybeStartPolling() {
    if (!_pollingEnabled || !_demanded || !AppActivity.isVisible) return;
    _timer ??= Timer.periodic(_pollEvery, (_) => _poll());
  }

  static void _onActivity() {
    if (AppActivity.isVisible) {
      if (_pollingEnabled && _demanded) {
        _poll();
        _maybeStartPolling();
      }
    } else {
      // Hidden: the verdict is false whatever a probe would say, so the timer
      // can rest until the window is back.
      _timer?.cancel();
      _timer = null;
      _fullscreen = false;
      _update();
    }
  }

  static void _poll() {
    final blocked = (probeOverride ?? _probe)();
    if (blocked == _fullscreen) return;
    _fullscreen = blocked;
    _update();
  }

  static bool _probe() {
    try {
      WindowShell.ensureInitialized();
      // With no window of our own there is nothing to be covered *by*: the
      // runner exports its handle before Dart starts, so 0 means a test — or a
      // runner that could not identify its window — and the honest answer to
      // "is something over us" is no. Answering yes there would let an
      // unrelated window on the machine silence a launcher that is not even on
      // screen.
      final hwnd = WindowShell.hwnd;
      if (hwnd == 0) return false;
      // Two ways to be out of sight: an app fullscreen over its monitor (which
      // is the Wallpaper Engine rule), or anything at all covering our own
      // window — a borderless game, a maximized browser over a windowed
      // launcher. Either one leaves nothing of us on screen.
      return foregroundFullscreen(hwnd) || foregroundCovers(hwnd);
    } catch (_) {
      return false;
    }
  }

  static void _update() {
    allowed.value = AppActivity.isVisible && !_fullscreen && !_occluded;
  }

  /// Test seam: one probe right now, without waiting on the timer.
  @visibleForTesting
  static void pollNow() => _poll();

  /// Test seam: takes the gate back down — the timer, the demand and the
  /// activity listener with it — so a test does not leave a periodic timer
  /// pending.
  @visibleForTesting
  static void stop() {
    _demanded = false;
    _pollingEnabled = false;
    _timer?.cancel();
    _timer = null;
    _fullscreen = false;
    _occluded = false;
    AppActivity.visible.removeListener(_onActivity);
    allowed.value = true;
  }
}
