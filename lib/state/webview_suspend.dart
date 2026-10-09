import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'wallpaper_gate.dart';

/// Holds a wallpaper webview's controller and suspends the browser while
/// [WallpaperGate] says live surfaces must not run — the window hidden, or a
/// fullscreen app over the wallpaper.
///
/// Suspending is the plugin's `pause()`: WebView2 `IsVisible=false` plus
/// `TrySuspend`, which stops the renderer's compositing (the last frame stays
/// on the texture) and its timers with it. A scene then costs no GPU at all
/// instead of sixty frames a second, and an author's web page stops animating
/// without anyone having to understand it. `resume()` brings it back.
class WebviewSuspender {
  InAppWebViewController? _controller;
  bool _listening = false;

  /// Starts following the gate. Idempotent.
  void listen() {
    if (_listening) return;
    _listening = true;
    WallpaperGate.ensure();
    WallpaperGate.allowed.addListener(_apply);
  }

  /// The controller arrives with the platform view. Also re-applied after a
  /// navigation: the suspension belongs to the native view, but a page that
  /// loaded while gated off has not been seen by it yet, so the answer is
  /// applied again once there is something to apply it to.
  void attach(InAppWebViewController controller) {
    _controller = controller;
    _apply();
  }

  /// Applies the gate's current verdict again — after a page has finished
  /// loading, say, when the page itself did not exist for the last one.
  void reapply() => _apply();

  void dispose() {
    if (_listening) WallpaperGate.allowed.removeListener(_apply);
    _listening = false;
    _controller = null;
  }

  void _apply() {
    final controller = _controller;
    if (controller == null) return;
    if (WallpaperGate.allowed.value) {
      _run(controller.resume);
    } else {
      _run(controller.pause);
    }
  }

  /// A failed suspend/resume only costs the power it was meant to save; the
  /// wallpaper keeps working either way.
  static Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }
}
