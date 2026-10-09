import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../state/live_surfaces.dart';
import '../state/wallpaper_server.dart';
import '../state/webview_suspend.dart';

/// The live half of a scene wallpaper: the package rendered by the WebGL
/// renderer the app ships, inside the in-app browser.
///
/// The Windows implementation of the webview plugin paints the browser into a
/// Flutter texture, so the scene sits *under* the app UI exactly like a video
/// or a still does. The author's preview picture stays underneath while the
/// package is fetched and compiled — a 5 MB pkg takes a moment, and a blank
/// window reads as a bug — and it is all that is shown when WebGL2 is missing,
/// so a scene degrades to a picture rather than to nothing.
class SceneBackground extends StatefulWidget {
  const SceneBackground({
    super.key,
    required this.pkgPath,
    required this.fit,
    this.posterOnly = false,
    this.fps = 30,
  });

  /// Absolute path of the wallpaper's `scene.pkg`.
  final String pkgPath;

  /// How the scene fills the window.
  final BoxFit fit;

  /// The settings preview sets this: a second renderer for a 16:9 thumbnail
  /// costs another WebGL context and another pkg parse, so the card shows the
  /// still instead.
  final bool posterOnly;

  /// The rate the renderer draws at, in fps. It rides the URL like the fit
  /// does; the renderer's page clamps and falls back to its own budget when
  /// the value is missing or out of range.
  final int fps;

  /// Test seam: replaces the browser surface (widget tests have no browser).
  static Widget Function(SceneBackground widget)? builderOverride;

  /// How a package becomes the page that renders it: the loopback server,
  /// unless a test substitutes its own (a socket needs a real event loop,
  /// which widget tests do not have).
  static Future<String?> Function(String pkgPath) urlResolver =
      WallpaperServer.scenePageUrl;

  @override
  State<SceneBackground> createState() => _SceneBackgroundState();
}

class _SceneBackgroundState extends State<SceneBackground> {
  String? _poster;

  /// The registered render page for [SceneBackground.pkgPath], without the fit
  /// query — the fit rides the URL at build time, so changing it swaps the
  /// page like a wallpaper change does.
  String? _baseUrl;

  /// The browser goes to sleep whenever the wallpaper is gated off — window
  /// hidden, or a fullscreen app over it. The last frame stays on the texture,
  /// so the poster's job (cover the gap until the renderer paints) is done
  /// exactly once regardless.
  final _suspender = WebviewSuspender();

  bool get _canRender =>
      !widget.posterOnly &&
      LiveSurfaces.scene &&
      SceneBackground.builderOverride == null;

  @override
  void initState() {
    super.initState();
    _poster = _findPoster();
    // No server, no browser: a test that swapped in [builderOverride] must not
    // have the real renderer started underneath it.
    if (_canRender) {
      _suspender.listen();
      _start();
    }
  }

  @override
  void didUpdateWidget(SceneBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pkgPath == widget.pkgPath) return;
    // A scene → scene switch reuses this very state — same widget type, same
    // position, no key — so without this hook the old package's page and
    // poster would stay up forever. Drop the old page: the poster (already
    // the new package's) shows while the new renderer page resolves.
    setState(() {
      _baseUrl = null;
      _poster = _findPoster();
    });
    if (_canRender) _start();
  }

  @override
  void dispose() {
    _suspender.dispose();
    super.dispose();
  }

  /// The author's own preview picture, shipped next to the package.
  String? _findPoster() {
    final dir = File(widget.pkgPath).parent;
    for (final name in const [
      'preview.jpg', 'preview.png', 'preview.jpeg', 'preview.gif', 'preview.webp',
    ]) {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  Future<void> _start() async {
    final pkg = widget.pkgPath;
    final url = await SceneBackground.urlResolver(pkg);
    // A quick switch may already point at another package; its own _start
    // answers then, and this stale result must not land.
    if (!mounted || url == null || widget.pkgPath != pkg) return;
    setState(() => _baseUrl = url);
  }

  /// The poster only has to cover this window, so a 4K preview decodes down to
  /// it. Null (no view data, as in tests) leaves the file's own size alone.
  static int? _posterCacheWidth(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return null;
    final width = (media.size.width * media.devicePixelRatio).round();
    return width <= 0 ? null : width.clamp(320, 3840);
  }

  @override
  Widget build(BuildContext context) {
    final override = SceneBackground.builderOverride;
    if (override != null) return override(widget);
    final poster = _poster;
    final still = poster == null
        ? const SizedBox.shrink()
        : RepaintBoundary(
            child: Image.file(
              File(poster),
              fit: widget.fit,
              // The poster is a full-window picture only until the renderer
              // paints over it; decoding a 4K one at its own size would cost
              // tens of MB for the same result.
              cacheWidth: _posterCacheWidth(context),
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          );
    final base = _baseUrl;
    if (base == null || widget.posterOnly) return still;
    // A new wallpaper (or fit, or rate) means a new page: the plugin keeps the
    // URL it was built with, so the key is what makes it reload.
    final url =
        '$base${base.contains('?') ? '&' : '?'}fit=${widget.fit == BoxFit.contain ? 'contain' : 'cover'}&fps=${widget.fps}';
    return Stack(
      fit: StackFit.expand,
      children: [
        still,
        IgnorePointer(
          child: InAppWebView(
            key: ValueKey(url),
            initialUrlRequest: URLRequest(url: WebUri(url)),
            onWebViewCreated: _suspender.attach,
            onLoadStop: (_, _) => _suspender.reapply(),
            initialSettings: InAppWebViewSettings(
              transparentBackground: true,
              supportZoom: false,
              disableContextMenu: true,
              isInspectable: false,
            ),
          ),
        ),
      ],
    );
  }
}
