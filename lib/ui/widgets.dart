import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../state/app_power.dart';
import '../state/background_glass.dart';
import '../state/settings_provider.dart';
import '../state/wallpaper_gate.dart';
import 'nav.dart';

/// True when the user asked the OS to reduce motion.
bool reducedMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Whether the shell should skip its decorative motion.
///
/// Two reasons, one verdict: the user asked the OS for less motion, or the
/// low-power profile is in force (a handheld, or somebody who turned it on for
/// one). Both mean the same thing to a widget — go straight to the finished
/// state — so both are asked here rather than at every call site.
///
/// [AppPower] is read, not watched: the widgets that follow this rebuild for
/// reasons of their own — a reading a second, a section entrance — so a profile
/// that lands between two of those rebuilds costs one frame of motion instead
/// of a subscription per readout.
bool motionless(BuildContext context) =>
    reducedMotion(context) || AppPower.isEconomy;

/// Whether an eased readout is worth easing right now.
///
/// A number that eases to its new value renders the window at vsync for the
/// length of the tween, which is the whole point while somebody is looking at
/// it — and pure waste when nobody is: the launcher hidden, or a game
/// fullscreen over it. [WallpaperGate] is the verdict the live wallpapers
/// already follow, folded from exactly those two facts, so the telemetry
/// stands down with them and the panel stops clocking frames behind a game.
///
/// Read straight off the notifier rather than listened to, for the same reason
/// as [motionless]: the panel rebuilds on every 1 Hz reading anyway.
bool telemetryAnimates(BuildContext context) =>
    !motionless(context) && WallpaperGate.allowed.value;

/// Frosts whatever is painted behind [child] — the wallpaper, in this app —
/// and clips the panel to [radius].
///
/// The wallpaper runs under the whole window, so an opaque panel on top of it
/// hides the very thing the user picked it to see. A frosted panel blurs its
/// backdrop instead and keeps a translucent fill ([AppColors.frost]), so the
/// picture — or the video, or the scene — stays visible as color and motion
/// behind the content, the way a native acrylic flyout does.
///
/// [child] paints the fill itself, which is what lets a caller animate it.
/// Leave this out of the tree entirely while a panel is not showing (see the
/// app tiles): every instance reads its own area of the frame back each frame.
/// It also steps aside on its own when the blur cannot buy anything: with no
/// wallpaper the backdrop is the flat theme background, whose blur is the same
/// pixels as no blur at all, and [blur] 0 is what a caller passes for a sheet
/// that should fill but never read the frame back (a tile under the mouse).
///
/// Over a *still* wallpaper there is a third option, and [wallpaperOnly] is
/// how a panel asks for it: when nothing but the wallpaper is behind — the
/// apps pane's own chrome — the panel samples [BackgroundGlass], the copy the
/// background layer baked once, instead of reading the frame back. Same glass,
/// none of the per-frame work. See [WallpaperSample].
class Frosted extends StatelessWidget {
  const Frosted({
    super.key,
    required this.child,
    this.radius = 12,
    this.blur = BackgroundGlass.frostSigma,
    this.wallpaperOnly = false,
  });

  final Widget child;
  final double radius;
  final double blur;

  /// True for a panel that sits on the desktop with nothing but the wallpaper
  /// behind it: the apps pane's search field, its view toggle and the category
  /// strip. Over a still wallpaper such a panel samples the baked copy; when
  /// it does fall back to a real filter — a live wallpaper, or the bake still
  /// on its way — it shares one backdrop with the other panels of its
  /// `BackdropGroup` rather than reading the frame back once each.
  ///
  /// Leave this false wherever the backdrop carries content (a popup over the
  /// grid, a tile, the soft keyboard): their glass has to blur what is
  /// actually there, which is not the wallpaper alone.
  final bool wallpaperOnly;

  @override
  Widget build(BuildContext context) {
    final wallpapered = context.select<SettingsProvider, bool>(
        (settings) => settings.backgroundPath != null);
    Widget panel = child;
    if (wallpapered && blur > 0.01) {
      if (!wallpaperOnly) {
        panel = BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: child,
        );
      } else {
        panel = ValueListenableBuilder<GlassBackdrop?>(
          valueListenable: BackgroundGlass.current,
          builder: (context, glass, child) {
            // Only a copy baked for exactly this blur may stand in for the
            // filter; anything else would be a pane of glass that does not
            // match the panels beside it.
            if (glass != null && (glass.sigma - blur).abs() < 0.5) {
              return WallpaperSample(glass: glass, child: child!);
            }
            return BackdropFilter.grouped(
              filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: child!,
            );
          },
          child: child,
        );
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: panel,
    );
  }
}

/// Paints the crop of the baked wallpaper that lies behind [child].
///
/// The crop is taken in *window* coordinates rather than the panel's own: the
/// background is painted outside immersive mode's magnifier, so a magnified
/// panel has to sample the wallpaper where it actually sits on the screen.
/// `getTransformTo(null)` is that mapping — it carries the magnifier's scale
/// along with every other ancestor transform.
class WallpaperSample extends SingleChildRenderObjectWidget {
  const WallpaperSample({super.key, required this.glass, super.child});

  final GlassBackdrop glass;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderWallpaperSample(glass);

  @override
  void updateRenderObject(
      BuildContext context, RenderWallpaperSample renderObject) {
    renderObject.glass = glass;
  }
}

/// The box [WallpaperSample] paints through: it takes no space of its own and
/// passes everything on to the child.
class RenderWallpaperSample extends RenderProxyBox {
  RenderWallpaperSample(this._glass);

  GlassBackdrop _glass;

  set glass(GlassBackdrop value) {
    if (identical(value, _glass)) return;
    _glass = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!size.isEmpty) {
      // Local rect → window rect → the baked copy's own pixels. The copy is a
      // still picture, so a point smaller than a pixel of it is nobody's
      // concern; the low-quality sampler is what keeps this a texture read.
      final scale = _glass.pixelsPerLogical;
      final inWindow =
          MatrixUtils.transformRect(getTransformTo(null), Offset.zero & size);
      final source = Rect.fromLTRB(
        inWindow.left * scale,
        inWindow.top * scale,
        inWindow.right * scale,
        inWindow.bottom * scale,
      );
      if (!source.isEmpty) {
        context.canvas.drawImageRect(
          _glass.image,
          source,
          offset & size,
          Paint()..filterQuality = FilterQuality.low,
        );
      }
    }
    super.paint(context, offset);
  }
}

/// Live number readout. Counts up from zero on first appearance (part of the
/// one boot-up sequence), then eases to each new value as data arrives.
///
/// Telemetry jitters: a reading that moved less than [snapAt] lands directly
/// instead of easing, so the probe's 1 Hz updates do not keep the window
/// rendering at vsync while the machine is doing nothing. The default scales
/// with the reading's magnitude — 2 °C snaps, a 10 W swing still eases.
class FlipValue extends StatefulWidget {
  const FlipValue(
    this.value, {
    super.key,
    required this.style,
    this.suffix,
    this.fractionDigits = 0,
    this.duration = const Duration(milliseconds: 600),
    this.snapAt,
  });

  final double? value;
  final TextStyle style;
  final String? suffix;
  final int fractionDigits;
  final Duration duration;

  /// Smallest change that is worth easing to, in the value's own units.
  /// Null means a magnitude-scaled default (see [_defaultSnapAt]).
  final double? snapAt;

  static double _defaultSnapAt(double value) =>
      math.max(3.0, value.abs() * 0.015);

  @override
  State<FlipValue> createState() => _FlipValueState();
}

class _FlipValueState extends State<FlipValue> {
  double? _shown;

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    if (value == null) {
      return Text('--', style: widget.style);
    }
    if (!telemetryAnimates(context)) {
      // The style rides along even when the easing does not: dropping it
      // falls the number back to the default body face and size, which
      // detaches it from the styled suffix (the '%') sitting next to it.
      return Text(
        value.toStringAsFixed(widget.fractionDigits) + (widget.suffix ?? ''),
        style: widget.style,
      );
    }
    final last = _shown;
    _shown = value;
    final eased =
        last == null || (value - last).abs() >= _snapAtFor(value);
    return TweenAnimationBuilder<double>(
      // First appearance counts up from zero (part of the boot sequence);
      // later targets ease from wherever the text sits now.
      tween: Tween(begin: last == null ? 0 : null, end: value),
      duration: eased ? widget.duration : Duration.zero,
      curve: Motion.outCubic,
      builder: (context, v, _) {
        // The style must ride along on every intermediate frame too: without
        // it the number falls back to the default body face and size, which
        // detaches it from the styled suffix (the '%') sitting next to it.
        return Text(
          v.toStringAsFixed(widget.fractionDigits) + (widget.suffix ?? ''),
          style: widget.style,
        );
      },
    );
  }

  double _snapAtFor(double value) =>
      widget.snapAt ?? FlipValue._defaultSnapAt(value);
}

/// A thin horizontal meter. The fill eases to each new value and shifts
/// color through the warning/danger thresholds.
///
/// Like [FlipValue], a move smaller than [snapAt] percentage points lands
/// directly — utilization readings wobble by less than that every second,
/// and easing each wobble would keep the whole window rendering at vsync.
class MeterBar extends StatefulWidget {
  const MeterBar({
    super.key,
    required this.value,
    required this.color,
    this.height = 5,
    this.snapAt = 8.0,
  });

  final double? value; // 0..100
  final Color color;
  final double height;

  /// Smallest change that is worth easing to, in percentage points.
  final double snapAt;

  @override
  State<MeterBar> createState() => _MeterBarState();
}

class _MeterBarState extends State<MeterBar> {
  double? _shown;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: c.barTrack,
        borderRadius: BorderRadius.circular(widget.height),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.centerLeft,
      child: widget.value == null
          ? null
          : TweenAnimationBuilder<double>(
              tween: Tween(end: (widget.value! / 100).clamp(0.0, 1.0)),
              duration: _eased && telemetryAnimates(context)
                  ? Motion.slow
                  : Duration.zero,
              curve: Motion.outCubic,
              builder: (context, t, _) => FractionallySizedBox(
                widthFactor: t,
                child: Container(color: widget.color),
              ),
            ),
    );
  }

  bool get _eased {
    final value = widget.value;
    final last = _shown;
    _shown = value;
    return last == null || (value! - last).abs() >= widget.snapAt;
  }
}

/// A row of mutually exclusive choices in a bordered pill: what a console
/// calls a radio group, and the control every settings row with two or three
/// states uses. Picked by pointer, walked by the pad (each option is a
/// [TouchTarget] with a focus ring of its own).
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (option, label) in options)
            Tappable(
              onTap: () => onChanged(option),
              builder: (context, state) => TouchTarget(
                minSize: const Size(0, 44),
                child: AnimatedContainer(
                  duration: Motion.base,
                  curve: Motion.outCubic,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                  decoration: BoxDecoration(
                    color: option == value
                        ? c.accentDim
                        : state.highlighted
                            ? c.surfaceHover
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    // Always there, transparent at rest: with only the fill and
                    // the label changing, the pad's ring was invisible here.
                    border: Border.all(
                      color: state.focused ? c.accent : Colors.transparent,
                    ),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: option == value
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: option == value
                          ? c.accent
                          : state.highlighted
                              ? c.textPrimary
                              : c.textMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Minimal polyline chart for the last N samples. Flat translucent fill —
/// no gradient.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.height = 34,
    this.strokeWidth = 1.5,
  });

  final List<double> values;
  final Color color;
  final double height;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: values,
          color: color,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.color,
    required this.strokeWidth,
  });

  final List<double> values;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxY = math.max(values.reduce(math.max), 1.0);
    final minY = 0.0;
    final span = (maxY - minY).abs() < 0.001 ? 1.0 : maxY - minY;
    final dx = size.width / (values.length - 1);

    Offset point(int i) => Offset(
          i * dx,
          size.height -
              ((values[i] - minY) / span).clamp(0.0, 1.0) *
                  (size.height - 3) -
              1.5,
        );

    final path = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(point(i).dx, point(i).dy);
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      // By value, not by identity: the caller hands in a fresh list each
      // build, and identity comparison therefore repainted the curve on every
      // single telemetry tick whether the data moved or not.
      !listEquals(old.values, values);
}

/// One-time entrance: fades and slides in after [delay]. Used for the single
/// boot-up sequence; skipped entirely when motion is reduced, and when
/// [animate] is false, which shows the child already at rest (recycled list
/// items must not replay the sequence as they scroll in and out of view).
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 14),
    this.animate = true,
  });

  final Duration delay;
  final Offset offset;
  final bool animate;
  final Widget child;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Motion.slow,
      value: 0,
    );
    _animation = CurvedAnimation(parent: _controller, curve: Motion.outQuint);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (motionless(context) || !widget.animate) {
      _controller.value = 1;
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final t = _animation.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(widget.offset.dx * (1 - t),
                widget.offset.dy * (1 - t)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// How a [GhostButton] reads: a plain outline, the accent, or the colour that
/// means "this throws something away".
enum GhostButtonTone { plain, accent, danger }

/// The outlined button the full-screen pages use — a low-emphasis action
/// beside whatever it belongs to. A null [onTap] leaves the button drawn but
/// inert, which is how a page says "nothing to do here yet" without hiding the
/// control and shifting everything around it.
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.tone = GhostButtonTone.plain,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final GhostButtonTone tone;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final enabled = onTap != null;
    final ink = switch (tone) {
      GhostButtonTone.plain => c.textPrimary,
      GhostButtonTone.accent => c.accent,
      GhostButtonTone.danger => c.danger,
    };
    final edge = switch (tone) {
      GhostButtonTone.plain => c.borderStrong,
      GhostButtonTone.accent => c.accent,
      GhostButtonTone.danger => c.danger,
    };
    final wash = switch (tone) {
      GhostButtonTone.plain => c.surfaceHover,
      GhostButtonTone.accent => c.accentDim,
      GhostButtonTone.danger => c.danger.withValues(alpha: 0.14),
    };
    return Tappable(
      onTap: onTap,
      enabled: enabled,
      builder: (context, state) => TouchTarget(
        minSize: const Size(0, 44),
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.outCubic,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: !enabled
                ? Colors.transparent
                : state.highlighted
                    ? wash
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: enabled
                  ? (state.focused ? c.accent : edge)
                  : c.border,
              width: state.focused ? 1.4 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: enabled ? ink : c.textMuted),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: enabled ? ink : c.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The round close button in a full-screen page's header. It takes its own key
/// so a page's tests can aim at it.
class PageCloseButton extends StatelessWidget {
  const PageCloseButton({
    super.key,
    required this.onTap,
    this.tooltip = '关闭 (Esc)',
  });

  final VoidCallback onTap;

  /// Spelled out per page, because the pad's back button and Esc are what the
  /// tooltip is really advertising.
  final String tooltip;

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
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: state.highlighted ? c.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: state.focused
                  ? c.accent
                  : state.hovering
                      ? c.borderStrong
                      : c.border,
            ),
          ),
          child: Icon(Icons.close_rounded, size: 15, color: c.textSecondary),
        ),
      ),
    );
  }
}
