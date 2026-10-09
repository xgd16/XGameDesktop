import 'dart:io';
import 'dart:ui' show Offset;

import 'win32_api.dart';

/// Frameless-window controls. The runner keeps WS_THICKFRAME but hands the
/// whole window rect to the client area (WM_NCCALCSIZE), so the system still
/// provides edge resizing and Aero Snap; here we drive caption drag and the
/// min/max/close buttons from Dart.
class WindowShell {
  WindowShell._();

  static int? _hwnd;
  static bool _immersive = false;
  static bool? _touch;

  /// Test seam: forces [hasTouch] instead of asking Windows.
  static bool? debugTouchOverride;

  /// Test seam: forces [bottomInset] instead of asking Windows.
  static int? debugBottomInsetOverride;

  /// Manual (touch/pen) drag state: where the window should sit in physical
  /// screen pixels, and where the finger was in the same space.
  static bool _dragging = false;
  static double _dragX = 0;
  static double _dragY = 0;
  static double _dragAnchorX = 0;
  static double _dragAnchorY = 0;

  static void ensureInitialized() {
    if (_hwnd != null) return;
    // Preferred: the runner exports its own HWND before Dart starts.
    final env = Platform.environment['XGAME_HWND'];
    _hwnd = int.tryParse(env ?? '') ?? findAppWindow();
  }

  static int get _window => _hwnd ?? 0;

  /// The runner's top-level window, 0 when it could not be identified. The
  /// wallpaper gate compares the foreground window against it, so the app's
  /// own immersive mode never reads as "another app went fullscreen".
  static int get hwnd => _window;

  /// Whether this app owns the foreground window. The pad is the only caller:
  /// it is polled globally, so a press belongs to us only while we are the
  /// window in front. Fail-open while the handle is unknown — a launcher that
  /// cannot identify its own window should still answer the pad.
  static bool get isForeground {
    ensureInitialized();
    return _window == 0 || appIsForeground(_window);
  }

  /// Whether the machine has a touch screen; the UI grows its hit targets and
  /// offers a soft keyboard when it does.
  static bool get hasTouch => debugTouchOverride ?? (_touch ??= hasTouchScreen());

  /// Whether the window is currently in immersive fullscreen.
  static bool get isImmersive => _immersive;

  /// True while a touch drag is moving the window.
  static bool get dragging => _dragging;

  /// The physical pixels along the window's bottom edge that the taskbar
  /// covers while blended immersive is up; 0 in a framed window, or when
  /// immersive stops above the bar. The bar stays on top through the blend,
  /// so anything the app anchors to its bottom edge has to clear this band.
  /// The UI lays out in logical pixels, so callers divide by the view's
  /// device pixel ratio.
  static int get bottomInset =>
      debugBottomInsetOverride ?? (_immersive ? immersiveBottomInset() : 0);

  /// Switches between the framed shell and immersive mode. With
  /// [taskbarBlend] the window covers the desktop down to the last pixel row
  /// and the taskbars on that monitor go transparent — showing the app's
  /// background, with [backdropColor] (Dart ARGB) filling the one-pixel seam
  /// at the bottom edge; without it the window stops above the taskbar.
  /// Best-effort: false means the window handle is not usable yet, and the
  /// page still magnifies inside the framed window.
  static bool setImmersive(
      bool on, {
        bool taskbarBlend = false,
        int backdropColor = 0xFF000000,
      }) {
    if (_window == 0 || on == _immersive) return _immersive == on;
    final ok = on
        ? enterFullscreen(_window,
            taskbarBlend: taskbarBlend, backdropColor: backdropColor)
        : exitFullscreen(_window);
    if (ok) _immersive = on;
    return ok;
  }

  /// Starts a native caption drag (call from a drag-start gesture). Only a
  /// mouse may use this — see [beginTouchDrag] for the rest.
  static void beginDrag() {
    if (_window != 0) beginCaptionDrag(_window);
  }

  /// Starts a drag a finger or a pen can drive. [position] is the pointer's
  /// position as Flutter reports it (logical, relative to the window) and
  /// [scale] the window's device pixel ratio.
  ///
  /// The pointer's *screen* position is reconstructed as `position * scale +
  /// window origin`: the window moves out from under the finger as the drag
  /// goes, so the reported position alone would chase its own tail.
  static void beginTouchDrag(Offset position, double scale) {
    final rect = _window == 0 ? null : windowRect(_window);
    if (rect == null) return;
    _dragX = rect.left.toDouble();
    _dragY = rect.top.toDouble();
    _dragAnchorX = position.dx * scale + _dragX;
    _dragAnchorY = position.dy * scale + _dragY;
    _dragging = true;
  }

  /// Moves the window by however far the finger travelled since the last
  /// update.
  static void updateTouchDrag(Offset position, double scale) {
    if (!_dragging) return;
    // The window sits at the rounded target, so that is what the finger's
    // position has to be measured against.
    final x = position.dx * scale + _dragX.round();
    final y = position.dy * scale + _dragY.round();
    final dx = x - _dragAnchorX;
    final dy = y - _dragAnchorY;
    if (dx.abs() < 0.5 && dy.abs() < 0.5) return;
    _dragX += dx;
    _dragY += dy;
    _dragAnchorX = x;
    _dragAnchorY = y;
    moveWindow(_window, _dragX.round(), _dragY.round());
  }

  static void endTouchDrag() {
    _dragging = false;
  }

  static void minimize() {
    if (_window != 0) minimizeWindow(_window);
  }

  static void toggleMaximize() {
    if (_window != 0) toggleMaximizeWindow(_window);
  }

  static void close() {
    if (_window != 0) closeWindow(_window);
  }
}
