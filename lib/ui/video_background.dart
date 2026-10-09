import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../state/live_surfaces.dart';
import '../state/video_sessions.dart';

/// The live half of a video wallpaper: a media_kit `Video` surface fed by a
/// shared [VideoSession].
///
/// media_kit draws through a texture registered with the Flutter engine, so the
/// video really sits *under* the rest of the UI — the scrim, the app grid and
/// the title bar all stack on top of it like they do over a still picture.
class VideoBackground extends StatefulWidget {
  const VideoBackground({super.key, required this.path, required this.fit});

  final String path;
  final BoxFit fit;

  /// Test seam: replaces the native surface (widget tests have no libmpv).
  static Widget Function(VideoBackground widget)? builderOverride;

  @override
  State<VideoBackground> createState() => _VideoBackgroundState();
}

class _VideoBackgroundState extends State<VideoBackground> {
  VideoSession? _session;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(VideoBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _session?.release();
      _attach();
    }
  }

  @override
  void dispose() {
    _session?.release();
    _session = null;
    super.dispose();
  }

  void _attach() {
    if (!LiveSurfaces.video || VideoBackground.builderOverride != null) {
      return;
    }
    try {
      _session = VideoSession.acquire(widget.path);
    } catch (_) {
      // libmpv refused to load: show nothing rather than taking the UI down.
      _session = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final override = VideoBackground.builderOverride;
    if (override != null) return override(widget);
    final session = _session;
    if (session == null) return const ColoredBox(color: Colors.black);
    return Video(
      // A new video means a new player, and the size gating that decides
      // whether a frame is shown is captured when this widget's state is
      // created — from the player that was current then. The key gives the new
      // video a state of its own instead of leaving it judged by the old
      // video's streams.
      key: ValueKey(widget.path),
      controller: session.controller,
      fit: widget.fit,
      controls: NoVideoControls,
      // A wallpaper must not keep the display awake or grab the media keys.
      wakelock: false,
      filterQuality: FilterQuality.medium,
    );
  }
}
