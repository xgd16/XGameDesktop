import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/background_glass.dart';
import '../state/live_surfaces.dart';
import '../state/settings_provider.dart';
import 'scene_background.dart';
import 'video_background.dart';
import 'web_background.dart';

/// The wallpaper: the chosen picture, optionally blurred, under a flat scrim
/// of the theme background. The scrim is what keeps the grid, the panel and
/// the title bar legible on top of an arbitrary photo — the picture is
/// ambience, not content.
///
/// A still wallpaper is also the app's one chance to make its glass cheap: the
/// composed picture is baked once into [BackgroundGlass], and the panels that
/// sit on the desktop sample their crop of it instead of reading the frame
/// back every time they paint (see [Frosted.wallpaperOnly]).
///
/// Also used, at card size, as the live preview in the settings page.
class AppBackground extends StatefulWidget {
  const AppBackground({super.key, this.placeholder, this.sceneStill = false});

  /// Shown instead of the picture when none is set.
  final Widget? placeholder;

  /// The settings page's 16:9 card sets this: no live surface is spun up for a
  /// card that small. A scene shows its still (see [SceneBackground]) and a
  /// page shows a note, because a second WebView2 is a whole second renderer
  /// process, its own GPU compositing and a fresh download of every asset.
  final bool sceneStill;

  @override
  State<AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<AppBackground> {
  /// The composed background — picture, fit, blur, scrim and all. The bake is
  /// taken from this box rather than re-derived from the file, which is what
  /// keeps the sampled glass lined up with the picture it stands in for at any
  /// fit, any dim, and under the magnifier.
  final _boundary = GlobalKey(debugLabel: 'background');

  /// What the current bake was made from. A different picture, a resized
  /// window, a touched slider or a palette mid-transition is a new signature,
  /// and the copy is baked again.
  Object? _baked;

  /// The signature the copy on screen was made from. The later look stands
  /// down when the earlier one already landed.
  Object? _ready;

  /// The composed background itself, baked: picture, fit, blur and scrim in
  /// one image, and the only thing that paints once it exists.
  ///
  /// It is what keeps a wide gaussian off every frame. The live tree can only
  /// be trusted to the engine's raster cache, and a cache the engine decides
  /// not to keep — an evicted layer, a window whose raster budget moved, a
  /// magnifier that changed the scale — is a full-window gaussian again, which
  /// on a handheld is a spike the size of its screen. A copy is one texture
  /// read whatever the frame does.
  ui.Image? _copy;

  /// Whether the live composition is what paints right now: true until the
  /// copy for the current signature lands, and always true while the picture
  /// animates.
  bool _live = true;

  /// The picture being watched — its path and decode width — with the stream
  /// and the frame this state listens through. The bake waits on the pixels
  /// rather than on the clock alone: a timer can fire while the decode is
  /// still running, and the copy would then hold the frame before the picture.
  Object? _picture;
  ImageStream? _stream;
  ImageStreamListener? _frame;
  bool _landed = false;

  /// Set when the watched picture hands over a second frame: it moves (a GIF,
  /// an animated WebP), so there is nothing still to bake — the copy would
  /// freeze while the picture behind the glass keeps playing. Those panels
  /// stay on the live filter.
  bool _moving = false;

  /// Two looks per change: the picture decodes asynchronously and the first
  /// look can catch the frame before it lands (the previous one is still up —
  /// gapless playback), so a second look takes the finished composition. A
  /// change re-arms both, which is also what makes a burst of changes — the
  /// blur slider, a palette easing through 350 ms — bake once when it settles
  /// instead of once per frame.
  static const _lookDelay = Duration(milliseconds: 160);
  Timer? _look;
  Timer? _lateLook;
  bool _capturing = false;
  bool _published = false;

  @override
  void dispose() {
    _stopLooks();
    _stopWatch();
    _dropCopy();
    if (_published) BackgroundGlass.clear();
    super.dispose();
  }

  void _stopLooks() {
    _look?.cancel();
    _look = null;
    _lateLook?.cancel();
    _lateLook = null;
  }

  /// Releases the composed copy. Safe while a frame still paints it: the
  /// engine holds its own reference for as long as a layer needs one.
  void _dropCopy() {
    final copy = _copy;
    _copy = null;
    copy?.dispose();
  }

  void _stopWatch() {
    final frame = _frame;
    if (frame != null) _stream?.removeListener(frame);
    _stream = null;
    _frame = null;
    _landed = false;
  }

  /// Watches the picture's own stream — the very provider the [Image] below
  /// resolves, so the two share one decode. Its first frame is the signal the
  /// bake is waiting for; a second one means the picture animates.
  void _watch(File file, int? cacheWidth) {
    if (_stream != null) return;
    final ImageProvider provider = cacheWidth == null
        ? FileImage(file)
        : ResizeImage(FileImage(file), width: cacheWidth);
    _frame = ImageStreamListener((info, synchronous) {
      if (!mounted || _moving) return;
      if (_landed) {
        _moving = true;
        // Out of whatever frame this arrived in: retiring drops the baked
        // copy, and the panels listening to it rebuild around the filter.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _moving) _retire();
        });
        return;
      }
      _landed = true;
      final signature = _baked;
      // The picture's own frame: there are pixels to bake now, and this is not
      // the build that would have painted them.
      if (signature != null) _bake(signature, force: true, inBuild: false);
    });
    _stream = provider.resolve(ImageConfiguration.empty)..addListener(_frame!);
  }

  /// Schedules a bake of [signature] — unless that is what the current copy
  /// was already made from. [force] is for the picture's own frame arriving:
  /// the signature is unchanged, but now there are pixels to bake.
  void _bake(Object signature, {bool force = false, bool inBuild = true}) {
    if (!force && _baked == signature) return;
    _baked = signature;
    // Back to the live composition until this signature has a copy of its own.
    // Inside build this is just the flag the build itself reads — no setState,
    // which would be illegal there. From the picture's own frame arriving (a
    // listener, long after the copy landed) the tree is already showing the
    // copy, so the flag needs a rebuild of its own to get the live composition
    // — and with it the boundary the bake is taken from — back into the tree.
    if (inBuild) {
      _live = true;
    } else if (!_live) {
      setState(() => _live = true);
    }
    _stopLooks();
    _look = Timer(_lookDelay, () => _capture(signature));
    _lateLook = Timer(_lookDelay * 4, () => _capture(signature, late: true));
  }

  /// Drops the baked copy: there is nothing still to take it from.
  void _retire() {
    _stopLooks();
    _baked = null;
    _ready = null;
    _live = true;
    _dropCopy();
    if (_published) {
      _published = false;
      BackgroundGlass.clear();
    }
  }

  Future<void> _capture(Object signature, {bool late = false}) async {
    if (_capturing || !mounted || _baked != signature) return;
    // What paints right now is the copy itself. Baking it again would bake the
    // bake — a picture blurred twice — so a capture that finds the live
    // composition out of the tree simply stands down; the look that armed it
    // is the one that gets the boundary back.
    if (!_live) return;
    // Whatever the first look took stands; the later one is only for a decode
    // that landed behind it.
    if (late && _ready == signature) return;
    final boundary =
        _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    // Nothing laid out yet, or the box is mid-paint: the other look covers it.
    if (boundary == null || boundary.debugNeedsPaint) return;
    _capturing = true;
    try {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final blur = context.read<SettingsProvider>().effectiveBackgroundBlur;
      // The copy the background is drawn from is only worth having where the
      // gaussian is doing the softening anyway: past a few pixels of blur, half
      // the device pixels carry no detail it has not already destroyed, and
      // under that the picture is nearly sharp and is taken at full ratio.
      final keepCopy = blur > 0.1;
      final shotRatio = keepCopy && blur < 4 ? dpr : 0.5 * dpr;
      final shot = await boundary.toImage(pixelRatio: shotRatio);
      // The glass is always the half-ratio copy the panels were designed
      // around, whatever ratio the background was taken at.
      final glassRatio = 0.5 * dpr;
      final glass = await _frosted(shot, glassRatio / shotRatio, glassRatio);
      if (!mounted || _baked != signature) {
        shot.dispose();
        glass.dispose();
        return;
      }
      BackgroundGlass.publish(GlassBackdrop(
        image: glass,
        pixelsPerLogical: glassRatio,
        sigma: BackgroundGlass.frostSigma,
      ));
      _published = true;
      _ready = signature;
      if (!keepCopy) {
        // Nothing still to show from it — the live background is sharp here,
        // and the copy would only soften it — but it was worth taking: the
        // panels read their glass from the very same pixels.
        shot.dispose();
        if (_copy != null) setState(_dropCopy);
        return;
      }
      final previous = _copy;
      setState(() {
        _copy = shot;
        _live = false;
      });
      previous?.dispose();
    } catch (_) {
      // Best effort: a bake that fails leaves the panels on the live filter and
      // the background on the live composition, which is exactly what they did
      // before there was a copy to sample.
    } finally {
      _capturing = false;
    }
  }

  /// The one gaussian the panels would otherwise run every frame, spent once on
  /// a copy a quarter of the size, at the sigma a live filter of the frost's
  /// own width would have had there. [scale] takes [source] down to [outRatio]
  /// image pixels per logical pixel; the blur itself is in destination pixels,
  /// so it does not move with the scale.
  Future<ui.Image> _frosted(
      ui.Image source, double scale, double outRatio) async {
    final width = (source.width * scale).round();
    final height = (source.height * scale).round();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()
        ..filterQuality = FilterQuality.low
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: BackgroundGlass.frostSigma * outRatio,
          sigmaY: BackgroundGlass.frostSigma * outRatio,
          // Edge pixels rather than nothing: a panel near the window's edge
          // samples well inside the fade a decal-mode blur would leave.
          tileMode: ui.TileMode.clamp,
        ),
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final settings = context.watch<SettingsProvider>();
    final path = settings.backgroundPath;
    if (path == null) {
      _retire();
      return widget.placeholder == null
          ? const SizedBox.shrink()
          : Center(child: widget.placeholder);
    }

    // A live wallpaper (video / page / scene) runs from its original folder; a
    // picture is a copy in the data dir. All of them sit under the same scrim.
    final source = settings.backgroundSource;
    final isLive = source != BackgroundSource.image;
    // A wallpaper is never drawn larger than the window, so a 4K/8K source is
    // decoded down to it: the decode, the image cache entry and the upload all
    // shrink by the area ratio. Tiling is the exception — there the picture is
    // shown at its own size, and scaling the cache would shrink every tile.
    final tiled = settings.backgroundFit == BackgroundFit.tile;
    final cacheWidth = tiled ? null : _cacheWidth(context);
    Widget image = switch (source) {
      BackgroundSource.video => LiveSurfaces.video
          ? VideoBackground(path: path, fit: _videoFit(settings.backgroundFit))
          : const SizedBox.shrink(),
      BackgroundSource.web => _webSurface(settings, path, c),
      BackgroundSource.scene => LiveSurfaces.scene
          ? SceneBackground(
              pkgPath: path,
              fit: _videoFit(settings.backgroundFit),
              posterOnly: widget.sceneStill,
              // The low-power profile caps the rate here rather than in the
              // setting itself: the user's choice stays what they picked, and
              // the renderer simply draws it slower while the profile is on.
              fps: settings.effectiveSceneFps,
            )
          : const SizedBox.shrink(),
      BackgroundSource.image => Image.file(
          File(path),
          fit: switch (settings.backgroundFit) {
            BackgroundFit.cover => BoxFit.cover,
            BackgroundFit.contain => BoxFit.contain,
            BackgroundFit.tile => BoxFit.none,
          },
          repeat: tiled ? ImageRepeat.repeat : ImageRepeat.noRepeat,
          alignment: tiled ? Alignment.topLeft : Alignment.center,
          cacheWidth: cacheWidth,
          filterQuality: FilterQuality.medium,
          // Keeps the previous picture up while a new one decodes, so
          // switching wallpapers does not blink to the base color.
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
    };

    // Blur is a still-picture treatment; the live surfaces are left as they
    // are (a layer blur would read the engine's texture back every frame). The
    // sigma is the effective one — the low-power profile holds it well under
    // the slider's own maximum.
    final blur = settings.effectiveBackgroundBlur;
    if (!isLive && blur > 0.1) {
      // The blur fades the picture's own edges to nothing; scaling up pushes
      // those soft edges outside the window.
      // The boundary is what makes this affordable: a full-window gaussian is
      // rasterized once into its own layer, and the clock tick, a hover or the
      // boot animation repainting above it no longer re-runs the filter. A
      // blurred GIF would otherwise blur every animation frame. The layer is
      // only the *first* answer anyway — once this composition has been baked,
      // the window paints that copy instead (see [_copy]).
      image = RepaintBoundary(
        child: ClipRect(
          child: Transform.scale(
            scale: 1.1,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: blur,
                sigmaY: blur,
                tileMode: TileMode.decal,
              ),
              child: image,
            ),
          ),
        ),
      );
    }

    if (widget.sceneStill || isLive) {
      // Nothing still to bake: the card draws the same picture at card size and
      // must not publish on the window's behalf, and a live surface is a
      // backdrop that moves — the real filter is what the glass is for there.
      _retire();
      _stopWatch();
      _picture = null;
    } else {
      final picture = (path, cacheWidth);
      if (_picture != picture) {
        _stopWatch();
        _picture = picture;
        _moving = false;
      }
      if (_moving) {
        // The picture turned out to animate: no copy of it can stay true, so
        // the panels keep reading the frame back.
        _retire();
      } else {
        _watch(File(path), cacheWidth);
        final media = MediaQuery.of(context);
        _bake((
          path,
          settings.backgroundDim,
          blur,
          settings.backgroundFit,
          media.size,
          media.devicePixelRatio,
          // The scrim is the theme's own color, and AnimatedTheme eases it
          // through a palette switch: the copy carries that color, so it has to
          // bake again when the easing lands. A signature per frame of the
          // 350 ms costs nothing — the bake itself is re-armed, not repeated.
          c.bg,
        ));
      }
    }

    // What the window shows between bakes: the composed background, one texture
    // read per frame. Everything the live tree paints — the theme color, the
    // picture, its blur and the scrim — is already in it. The boundary stays in
    // the tree across the swap either way: it is the box the next bake is taken
    // from, and it has to be there — and painted — from the frame the live
    // composition comes back.
    final copy = _copy;
    return RepaintBoundary(
      key: _boundary,
      child: !_live && copy != null
          ? RawImage(
              image: copy,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.low,
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                // The theme's own color under the picture. The page paints it
                // too, but the bake has to be opaque on its own: a letterboxed
                // picture would otherwise record as a half-transparent copy and
                // the glass over it would come out lighter than the page around
                // it.
                ColoredBox(color: c.bg),
                image,
                ColoredBox(
                  key: const Key('backgroundScrim'),
                  color: c.bg.withValues(alpha: settings.backgroundDim),
                ),
              ],
            ),
    );
  }


  /// The page wallpaper — or, in the settings card, a note instead of a second
  /// WebView2 (a whole second renderer process for a 16:9 thumbnail).
  Widget _webSurface(SettingsProvider settings, String path, AppColors c) {
    if (widget.sceneStill) {
      return _WebStillPlaceholder(label: settings.backgroundLabel, c: c);
    }
    return LiveSurfaces.web
        ? WebBackground(path: path)
        : const SizedBox.shrink();
  }

  /// A video covers or fits; tiling is a still-picture option and falls back
  /// to cover.
  static BoxFit _videoFit(BackgroundFit fit) => switch (fit) {
        BackgroundFit.contain => BoxFit.contain,
        _ => BoxFit.cover,
      };

  /// The width the picture needs on this screen, in physical pixels, capped at
  /// 4K. Null (no view data) lets the decoder use the file's own size.
  static int? _cacheWidth(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return null;
    final width = (media.size.width * media.devicePixelRatio).round();
    if (width <= 0) return null;
    return width.clamp(320, 3840);
  }
}

/// What the settings card shows for a web wallpaper instead of running a second
/// copy of the page: the wallpaper's name, on the theme's own surface.
class _WebStillPlaceholder extends StatelessWidget {
  const _WebStillPlaceholder({required this.label, required this.c});

  final String? label;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: c.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.public, size: 22, color: c.textMuted),
            const SizedBox(height: 8),
            Text(
              label == null || label!.isEmpty ? '网页壁纸在窗口中运行' : label!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
