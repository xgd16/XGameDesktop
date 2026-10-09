import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../native/window_shell.dart';
import 'brand_mark.dart';
import 'nav.dart';
import 'theme_picker.dart';

/// Self-drawn frameless title bar: brand, palette switcher, the monitoring,
/// statistics and settings entries, window buttons. The whole bar is a native
/// caption-drag region; interactive children win hit testing over the drag
/// area.
class TitleBar extends StatelessWidget {
  const TitleBar({
    super.key,
    this.onToggleSettings,
    this.onToggleStats,
    this.onToggleMetrics,
    this.onImmersive,
    this.immersive = false,
    this.settingsOpen = false,
    this.statsOpen = false,
    this.metricsOpen = false,
  });

  /// Opens (or closes) the settings page; the button is hidden when null.
  final VoidCallback? onToggleSettings;

  /// Opens (or closes) the launch statistics; the button is hidden when null.
  final VoidCallback? onToggleStats;

  /// Opens (or closes) the device monitoring page; hidden when null.
  final VoidCallback? onToggleMetrics;

  /// Enters (or leaves) immersive fullscreen; the button is hidden when null.
  final VoidCallback? onImmersive;

  /// True while the window is immersive: the bar stays, but the window buttons
  /// and the caption drag go away with the frame they belong to.
  final bool immersive;

  final bool settingsOpen;
  final bool statsOpen;
  final bool metricsOpen;

  static bool _isFinger(PointerDeviceKind? kind) =>
      kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus;

  /// Starts a drag: the native caption loop for a mouse, a hand-rolled one for
  /// a finger or a pen — that modal loop waits for a mouse-up a touch contact
  /// never sends, so it would leave the window glued to the cursor.
  static void _startDrag(BuildContext context, DragStartDetails details) {
    if (_isFinger(details.kind)) {
      WindowShell.beginTouchDrag(
          details.globalPosition, MediaQuery.devicePixelRatioOf(context));
    } else {
      WindowShell.beginDrag();
    }
  }

  static void _updateDrag(BuildContext context, DragUpdateDetails details) {
    if (!WindowShell.dragging) return;
    WindowShell.updateTouchDrag(
        details.globalPosition, MediaQuery.devicePixelRatioOf(context));
  }

  Widget _dragRegion(BuildContext context, {required Widget child}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: immersive ? null : (details) => _startDrag(context, details),
      onPanUpdate:
          immersive ? null : (details) => _updateDrag(context, details),
      onPanEnd: immersive ? null : (_) => WindowShell.endTouchDrag(),
      onPanCancel: immersive ? null : WindowShell.endTouchDrag,
      onDoubleTap: immersive ? null : WindowShell.toggleMaximize,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          // Drag region around the brand; double-click here maximizes. The
          // double-tap recognizer must NOT wrap the window buttons — it
          // holds every tap in the arena for ~300 ms waiting for a second
          // tap, making the buttons feel laggy.
          _dragRegion(
            context,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 20),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  alignment: Alignment.center,
                  // The app mark, the same geometry the .ico is drawn from —
                  // flat white here so it reads at 13 px.
                  child: const BrandMark(size: 13, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Text(
                  'XGame Desktop',
                  style: TextStyle(
                    fontFamily: 'Rajdhani',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                    color: c.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          // Empty drag area between brand and controls.
          Expanded(
            child: _dragRegion(context, child: const SizedBox.expand()),
          ),
          const ThemePicker(),
          if (onImmersive != null) ...[
            const SizedBox(width: 10),
            _BarIconButton(
              icon: immersive
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              tooltip: immersive ? '退出沉浸模式 (F11)' : '沉浸模式 (F11)',
              active: immersive,
              onTap: onImmersive!,
            ),
          ],
          if (onToggleMetrics != null) ...[
            const SizedBox(width: 10),
            _BarIconButton(
              icon: Icons.monitor_heart_outlined,
              tooltip: '设备监控',
              active: metricsOpen,
              onTap: onToggleMetrics!,
            ),
          ],
          if (onToggleStats != null) ...[
            const SizedBox(width: 10),
            _BarIconButton(
              icon: Icons.insights_outlined,
              tooltip: '启动统计',
              active: statsOpen,
              onTap: onToggleStats!,
            ),
          ],
          if (onToggleSettings != null) ...[
            const SizedBox(width: 10),
            _BarIconButton(
              icon: Icons.settings_outlined,
              tooltip: '设置',
              active: settingsOpen,
              onTap: onToggleSettings!,
            ),
          ],
          if (!immersive) ...[
            const SizedBox(width: 8),
            const _WindowButtons(),
          ] else
            const SizedBox(width: 12),
        ],
      ),
    );
  }
}

/// A 32 px icon button in the title bar: accent-tinted when its panel is
/// open, filled on hover or when the pad's highlight is on it.
class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tappable(
      onTap: onTap,
      tooltip: tooltip,
      builder: (context, state) => TouchTarget(
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.outCubic,
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: active
                ? c.accentDim
                : state.highlighted
                    ? c.surfaceHover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: state.focused ? c.accent : Colors.transparent,
            ),
          ),
          child: Icon(
            icon,
            size: 16,
            color: active
                ? c.accent
                : state.highlighted
                    ? c.textPrimary
                    : c.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _WindowButtons extends StatelessWidget {
  const _WindowButtons();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    Widget button({
      required IconData icon,
      required VoidCallback onTap,
      Color? hoverColor,
      double iconSize = 16,
    }) {
      // Not focusable on purpose: the pad's X and Start must not be able to
      // close the window by accident.
      return Tappable(
        onTap: onTap,
        focusable: false,
        builder: (context, state) => TouchTarget(
          child: Container(
            width: 44,
            height: 32,
            color: state.highlighted ? hoverColor ?? c.surfaceHover : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(icon, size: iconSize, color: c.textSecondary),
          ),
        ),
      );
    }

    return Row(
      children: [
        button(icon: Icons.horizontal_rule, onTap: WindowShell.minimize),
        button(
          icon: Icons.crop_square_outlined,
          iconSize: 13,
          onTap: WindowShell.toggleMaximize,
        ),
        button(
          icon: Icons.close,
          onTap: WindowShell.close,
          hoverColor: const Color(0xFFE81123),
        ),
      ],
    );
  }
}
