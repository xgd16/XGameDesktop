/// Whether this process can run the *live* background surfaces.
///
/// Each one needs a native piece that only `main()` brings up: libmpv for video
/// wallpapers (media_kit) and WebView2 for page and scene wallpapers (the
/// in-app webview plugin). When a piece is missing the app still works — a
/// wallpaper of that kind simply comes in as a still picture instead — and
/// tests leave them all off, so nothing native is ever touched there.
class LiveSurfaces {
  LiveSurfaces._();

  /// libmpv loaded: video wallpapers can play.
  static bool video = false;

  /// The WebView2-backed webview is available: page wallpapers can run.
  static bool web = false;

  /// The same webview, plus WebGL2 and the bundled renderer: scene wallpapers
  /// are drawn from their package instead of falling back to a picture.
  static bool scene = false;
}
