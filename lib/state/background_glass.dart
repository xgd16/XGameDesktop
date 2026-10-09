import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// One baked backdrop: the app's background, at a fraction of its resolution,
/// already blurred with the frost's own sigma and dimmed by the scrim.
@immutable
class GlassBackdrop {
  const GlassBackdrop({
    required this.image,
    required this.pixelsPerLogical,
    required this.sigma,
  });

  /// The blurred copy. Owned by [BackgroundGlass], which releases it when it
  /// is replaced — publish a new one rather than disposing this by hand.
  final ui.Image image;

  /// Image pixels per window-logical pixel. Half the device pixel ratio: a
  /// blur this wide has no detail left to lose, and the copy shrinks and the
  /// gaussian with it.
  final double pixelsPerLogical;

  /// The blur baked into [image], in logical pixels. A panel asking for a
  /// different one must not sample this copy — it would read as a sharper or
  /// softer pane of glass than the panel beside it.
  ///
  /// It is the frost's own sigma, image scale or not: under immersive mode's
  /// magnifier the sampled glass is therefore the *windowed* blur of the
  /// picture, where a live filter would have had its sigma scaled up with the
  /// rest of the shell. The wallpaper is not magnified either, so the copy is
  /// the pane that matches the picture's own scale.
  final double sigma;
}

/// The still wallpaper, blurred once, for the panels that frost it.
///
/// A `BackdropFilter` reads the frame back every time it paints: its input is
/// whatever is on the screen at that moment, so none of that work can be
/// reused between frames — not even when the picture behind the panel never
/// changes. A still wallpaper is exactly that case, and it is the one the app
/// can bake: the pixels behind the glass are the same every frame, so
/// [AppBackground] composes them once, and a panel samples its own crop of the
/// result. The glass then costs a texture read per frame instead of a
/// framebuffer read plus a gaussian.
///
/// Live wallpapers never publish — their backdrop moves, and a filter that
/// follows it frame by frame is the point of the glass there. Null means
/// "nothing baked": no wallpaper, a live one, a bake still in flight, or a
/// test that mounted a panel without a background at all. Every reader falls
/// back to the real filter.
class BackgroundGlass {
  BackgroundGlass._();

  /// The blur a frosted panel defaults to — the sigma the baked backdrop
  /// carries, and therefore the one a panel must be asking for to sample it.
  static const double frostSigma = 18;

  /// The current bake, or null. Panels listen: the copy arrives a few frames
  /// after the wallpaper does, and the tree is rebuilt around it.
  static final ValueNotifier<GlassBackdrop?> current =
      ValueNotifier<GlassBackdrop?>(null);

  /// Replaces the bake, releasing the copy it displaces. Releasing is safe
  /// while a frame is still painting it: the engine holds its own reference
  /// for as long as a layer needs one.
  static void publish(GlassBackdrop? glass) {
    final previous = current.value;
    if (identical(previous, glass)) return;
    current.value = glass;
    previous?.image.dispose();
  }

  /// Drops the bake — the wallpaper went away, or the layer that made it is
  /// being disposed.
  static void clear() => publish(null);
}
