import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'state/live_surfaces.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    MediaKit.ensureInitialized();
    LiveSurfaces.video = true;
  } catch (_) {
    // libmpv unavailable: the app runs as usual and video wallpapers fall back
    // to a decoded still frame.
  }
  // The webview plugin is compiled into the Windows runner; pages and scenes
  // can run wherever the app itself can (scenes need WebGL2, which WebView2
  // provides).
  LiveSurfaces.web = Platform.isWindows;
  LiveSurfaces.scene = Platform.isWindows;
  runApp(const XGameApp());
}
