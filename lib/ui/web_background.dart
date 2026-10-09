import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../state/live_surfaces.dart';
import '../state/wallpaper_server.dart';
import '../state/webview_suspend.dart';

/// The live half of a web wallpaper: the author's own page (`index.html`)
/// running in WebView2.
///
/// The page is served over the loopback server rather than opened as a
/// `file://` URL: a file page has an opaque origin, and the browser then
/// refuses to load the page's own module scripts, stylesheets and fetches —
/// a bundled app (Vite, React, three.js) comes up black. Wallpaper Engine only
/// gets away with opening the file directly because its browser runs with the
/// web security switched off. Behind `127.0.0.1` the page has a real origin and
/// its relative paths are simply files next door.
///
/// The Windows implementation of the plugin renders the browser into a Flutter
/// texture, so the page sits *under* the app UI — the scrim, the grid and the
/// title bar stack on top of it exactly like they do over a video or a still.
/// Pointer events are ignored on purpose: the UI above owns the mouse.
class WebBackground extends StatefulWidget {
  const WebBackground({super.key, required this.path});

  /// Absolute path of the wallpaper's entry page.
  final String path;

  /// Test seam: replaces the WebView2 surface (widget tests have no browser).
  static Widget Function(WebBackground widget)? builderOverride;

  /// How a page on disk becomes something the browser can open: the loopback
  /// server, unless a test substitutes its own (a socket needs a real event
  /// loop, which widget tests do not have).
  static Future<String?> Function(String path) urlResolver =
      WallpaperServer.webPageUrl;

  @override
  State<WebBackground> createState() => _WebBackgroundState();
}

class _WebBackgroundState extends State<WebBackground> {
  String? _url;

  /// The author's page cannot be paused from outside, but the browser itself
  /// can: gated off (window hidden, fullscreen app over it), the whole webview
  /// suspends and the page's animations stop costing anything.
  final _suspender = WebviewSuspender();

  @override
  void initState() {
    super.initState();
    // No browser, nothing to suspend: a test that swapped in [builderOverride]
    // must not have the gate followed underneath it.
    if (LiveSurfaces.web && WebBackground.builderOverride == null) {
      _suspender.listen();
    }
    _start();
  }

  @override
  void didUpdateWidget(WebBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _start();
  }

  @override
  void dispose() {
    _suspender.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!LiveSurfaces.web || WebBackground.builderOverride != null) return;
    final requested = widget.path;
    final hosted = await WebBackground.urlResolver(requested);
    // A quick switch may already point at another page; its own _start answers
    // then, and this stale result must not land.
    if (!mounted || widget.path != requested) return;
    // No loopback socket (or a test): the plain file URL is still the right
    // answer for a page that is one script-less document.
    setState(() => _url = hosted ?? Uri.file(requested).toString());
  }

  @override
  Widget build(BuildContext context) {
    final override = WebBackground.builderOverride;
    if (override != null) return override(widget);
    if (!LiveSurfaces.web) return const SizedBox.shrink();
    final url = _url;
    if (url == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: InAppWebView(
        // A different wallpaper is a different page, and the browser is born
        // with its URL: the Windows plugin hands the creation parameters to
        // the native view once and never re-reads them, so switching wallpapers
        // would otherwise keep the old page on screen. The key is what makes
        // the platform view — and the navigation — happen again.
        key: ValueKey(url),
        initialUrlRequest: URLRequest(url: WebUri(url)),
        onWebViewCreated: _suspender.attach,
        onLoadStop: (_, _) => _suspender.reapply(),
        initialSettings: InAppWebViewSettings(
          // The page is the wallpaper, not a panel: it must let the app's own
          // background show through wherever it draws nothing.
          transparentBackground: true,
          // Ambience has no controls.
          supportZoom: false,
          disableContextMenu: true,
          isInspectable: false,
        ),
      ),
    );
  }
}
