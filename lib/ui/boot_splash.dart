import 'dart:async';

import 'package:flutter/material.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../state/app_power.dart';
import 'brand_mark.dart';
import 'widgets.dart';

/// The window's opening screen.
///
/// It exists to buy the load time: the app catalog, the search index, the app
/// icons, the wallpaper and the hardware probe all keep loading behind it, so
/// the shell underneath is never seen half-built. What it shows is the icon
/// assembling itself — the tile lands, the mark's two arms draw across it, the
/// stick drops into the crossing — over a hairline that reports the load
/// honestly, phase by phase, in the shell's own words.
///
/// When the load is done the field shatters: the four quadrants, whose cut
/// lines are the mark's own arms, fly to the corners and hand the window over.
/// That split is the one bold moment; everything before it is quiet.
///
/// The widget owns only the animation. What is loading, how far along it is and
/// when it is done come in as plain values, so the shell decides and this draws
/// — and so it can be driven from a test without a catalog at all.
class BootSplash extends StatefulWidget {
  const BootSplash({
    super.key,
    required this.progress,
    required this.label,
    required this.ready,
    this.skipped = false,
    this.onSkip,
    this.onRevealed,
    this.onFinished,
  });

  /// How much of the load is done, 0..1. The hairline eases to it.
  final double progress;

  /// One line saying what is loading, in the words the shell itself uses.
  final String label;

  /// True once everything the opening screen waits for has landed.
  final bool ready;

  /// True once the user asked to cut the rest of the wait short.
  final bool skipped;

  /// Called on a pointer press anywhere: the user's "enough".
  final VoidCallback? onSkip;

  /// The field has started to split — the shell can take over.
  final VoidCallback? onRevealed;

  /// The field is gone.
  final VoidCallback? onFinished;

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash> with TickerProviderStateMixin {
  late final AnimationController _intro =
      AnimationController(vsync: this, duration: Motion.bootIntro);
  late final AnimationController _exit =
      AnimationController(vsync: this, duration: Motion.bootExit);

  /// One listenable for both controllers, built once: merged per build, the
  /// AnimatedBuilder would resubscribe every frame of the sequence.
  late final Listenable _ticking = Listenable.merge([_intro, _exit]);

  Timer? _holdTimer;
  bool _started = false;

  /// No assembly and no split: the user asked for no animation, or the
  /// low-power profile is in force. The load still gets its time — the icon is
  /// simply there from the first frame, and the shell takes over the moment it
  /// is ready.
  bool _reduced = false;
  bool _holdDone = false;
  bool _exitStarted = false;

  /// Whether the wait is over — either because the load finished or because the
  /// user asked to move on. Either way the screen has one last beat to show a
  /// finished hairline before it goes.
  bool get _asked => widget.ready || widget.skipped;

  @override
  void initState() {
    super.initState();
    // The profile can still land while this screen is up: it mounts before the
    // settings file is read and before the hardware probe has answered, so on a
    // handheld "economy" is decided a beat *after* the first frame — and the
    // assembly this screen runs is exactly what the profile exists to skip.
    AppPower.economy.addListener(_onProfile);
    _intro.addStatusListener((status) {
      if (status == AnimationStatus.completed) _maybeStartExit();
    });
    _exit.addStatusListener((status) {
      if (status == AnimationStatus.completed) _post(widget.onFinished);
    });
  }

  /// The low-power profile came on mid-screen: land the assembly where it is and
  /// take the short way out from here on.
  void _onProfile() {
    if (!AppPower.isEconomy || _reduced) return;
    _reduced = true;
    if (!_intro.isCompleted) _intro.value = 1;
    if (_asked) _beginHold();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reduced = motionless(context);
    if (_reduced) {
      // No assembly for a user who asked for no animation — or for a handheld,
      // where the whole sequence is a few hundred frames of full-window raster
      // in front of a shell that is already loaded. The finished icon, and the
      // load still gets its time.
      _intro.value = 1;
    } else {
      _intro.forward();
    }
    if (_asked) _beginHold();
  }

  @override
  void didUpdateWidget(BootSplash old) {
    super.didUpdateWidget(old);
    if (_asked && !(old.ready || old.skipped)) _beginHold();
  }

  /// The load is done: hold the finished state for a beat, so a full hairline
  /// is read rather than blinked past, then leave.
  void _beginHold() {
    if (_exitStarted || _holdDone || _holdTimer != null) return;
    if (_reduced) {
      _holdDone = true;
      _maybeStartExit();
      return;
    }
    _holdTimer = Timer(Motion.bootHold, () {
      _holdTimer = null;
      _holdDone = true;
      _maybeStartExit();
    });
  }

  void _maybeStartExit() {
    if (_exitStarted || !_intro.isCompleted || !_holdDone) return;
    _exitStarted = true;
    _post(widget.onRevealed);
    if (_reduced) {
      // No split either: the shell is simply there once it is ready.
      _post(widget.onFinished);
      return;
    }
    _exit.forward();
  }

  /// Talks to the shell a frame later. `ready` flips while the shell is
  /// rebuilding — the value arrives with that build — and the callbacks
  /// setState on it, which is not allowed mid-build.
  void _post(VoidCallback? callback) {
    if (callback == null) return;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      if (mounted) callback();
    });
    binding.ensureVisualUpdate();
  }

  @override
  void dispose() {
    AppPower.economy.removeListener(_onProfile);
    _holdTimer?.cancel();
    _intro.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // The screen has the window while it is up: a press is the user saying
    // "enough", and it must not reach a shell nobody can see.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => widget.onSkip?.call(),
      child: AnimatedBuilder(
        animation: _ticking,
        builder: (context, _) {
          final field = _BootField(
            reveal: _intro.value,
            progress: widget.progress,
            label: widget.label,
            background: c.bg,
          );
          // Nothing to shatter for a user who asked for no animation.
          if (!_exitStarted || _reduced) return field;
          return _Shattered(progress: _exit.value, child: field);
        },
      ),
    );
  }
}

/// The field on its way out: four quadrants — split along the mark's own arms,
/// so each piece carries one arm — travelling to their corners. The gap opens
/// from the centre where the icon sits and widens until the shell is the only
/// thing left.
class _Shattered extends StatelessWidget {
  const _Shattered({required this.progress, required this.child});

  final double progress;
  final Widget child;

  /// How far the pieces travel, as a fraction of the window: a hair past the
  /// half it takes for a quadrant to clear its edge.
  static const _travel = 0.6;

  @override
  Widget build(BuildContext context) {
    final t = Motion.inOutCubic.transform(progress.clamp(0.0, 1.0));
    return LayoutBuilder(
      builder: (context, constraints) {
        final dx = constraints.maxWidth * _travel * t;
        final dy = constraints.maxHeight * _travel * t;
        return Stack(
          fit: StackFit.expand,
          children: [
            for (var quadrant = 0; quadrant < 4; quadrant++)
              Transform.translate(
                offset: Offset(
                  quadrant.isEven ? dx : -dx,
                  quadrant < 2 ? -dy : dy,
                ),
                child: ClipPath(
                  clipper: _QuadrantClipper(quadrant),
                  child: child,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One quarter of the window, extended far enough to cover it: 0 north-east,
/// 1 north-west, 2 south-east, 3 south-west.
class _QuadrantClipper extends CustomClipper<Path> {
  const _QuadrantClipper(this.quadrant);

  final int quadrant;

  @override
  Path getClip(Size size) {
    final reach = size.width + size.height;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final west = quadrant.isOdd;
    final north = quadrant < 2;
    return Path()
      ..addRect(Rect.fromLTRB(
        west ? cx - reach : cx,
        north ? cy - reach : cy,
        west ? cx : cx + reach,
        north ? cy : cy + reach,
      ));
  }

  @override
  bool shouldReclip(_QuadrantClipper old) => old.quadrant != quadrant;
}

/// What the opening screen paints: the icon, the wordmark, the load hairline
/// and its one line of copy, all centred on the flat theme background.
class _BootField extends StatelessWidget {
  const _BootField({
    required this.reveal,
    required this.progress,
    required this.label,
    required this.background,
  });

  /// 0..1 through the assembly. Drives the icon's own stages and the arrival of
  /// everything under it.
  final double reveal;

  final double progress;
  final String label;
  final Color background;

  /// A slice of the assembly, eased.
  static double _at(double t, double from, double to, Curve curve) =>
      curve.transform(((t - from) / (to - from)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = reveal.clamp(0.0, 1.0);
    final wordT = _at(t, 0.60, 0.95, Motion.outCubic);
    final meterT = _at(t, 0.68, 1.00, Motion.outCubic);
    final labelT = _at(t, 0.78, 1.00, Motion.outCubic);

    return ColoredBox(
      color: background,
      child: Center(
        // The whole block holds its final size from the first frame, so the
        // icon never shifts as the pieces under it arrive.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The window's one hero object: the app's own icon, at the size a
            // launch screen earns. It is the same geometry as the .ico, so
            // what the taskbar showed a moment ago is what assembles here.
            BrandMark(size: 132, tile: true, reveal: t),
            const SizedBox(height: 34),
            Opacity(
              opacity: wordT,
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - wordT)),
                // The title bar's own wordmark, a size up: the screen the
                // window opens on and the bar it hands over to say the same
                // thing in the same voice.
                child: Text(
                  'XGame Desktop',
                  style: TextStyle(
                    fontFamily: 'Rajdhani',
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                    color: c.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
            Opacity(opacity: meterT, child: _BootMeter(c: c, value: progress)),
            const SizedBox(height: 12),
            Opacity(opacity: labelT, child: _BootLabel(c: c, label: label)),
          ],
        ),
      ),
    );
  }
}

/// The load hairline: the same thin meter the search field carries for its
/// index pass, so the two read as one thing reporting the same work.
class _BootMeter extends StatelessWidget {
  const _BootMeter({required this.c, required this.value});

  final AppColors c;
  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 2,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0.0, 1.0)),
          duration: Motion.slow,
          curve: Motion.outCubic,
          builder: (context, v, _) => LinearProgressIndicator(
            value: v,
            minHeight: 2,
            color: c.accent,
            backgroundColor: c.barTrack,
          ),
        ),
      ),
    );
  }
}

class _BootLabel extends StatelessWidget {
  const _BootLabel({required this.c, required this.label});

  final AppColors c;
  final String label;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Motion.base,
      child: Text(
        label,
        key: ValueKey(label),
        style: TextStyle(fontSize: 12.5, color: c.textMuted),
      ),
    );
  }
}
