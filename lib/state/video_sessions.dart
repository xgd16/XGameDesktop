import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'wallpaper_gate.dart';

/// One libmpv player per video file, shared by everything that draws it.
///
/// The window background and the settings preview point at the same
/// [VideoController], so a video wallpaper is decoded once no matter how many
/// places show it. The last holder releases the player.
class VideoSession {
  VideoSession._(this.path, this.player, this.controller);

  final String path;
  final Player player;
  final VideoController controller;

  static final Map<String, VideoSession> _live = {};
  static bool _watchingGate = false;

  static VideoSession acquire(String path) {
    final key = path.toLowerCase();
    final existing = _live[key];
    if (existing != null) {
      existing._users++;
      return existing;
    }
    final player = Player();
    final session = VideoSession._(path, player, VideoController(player));
    _live[key] = session;
    _watchGate();
    unawaited(session._start());
    return session;
  }

  /// A wallpaper nobody can see must not keep decoding — a looping 4K video is
  /// the most expensive thing this app does, and it keeps the GPU awake for
  /// it. The gate covers both reasons a wallpaper goes unseen: the window
  /// hidden, and a fullscreen app over it. The listener lives as long as the
  /// process; sessions come and go underneath it.
  static void _watchGate() {
    if (_watchingGate) return;
    _watchingGate = true;
    WallpaperGate.ensure();
    WallpaperGate.allowed.addListener(_onGate);
  }

  static void _onGate() {
    final play = WallpaperGate.allowed.value;
    for (final session in _live.values) {
      unawaited(play ? session.player.play() : session.player.pause());
    }
  }

  int _users = 1;

  Future<void> _start() async {
    try {
      // A wallpaper loops forever and stays silent, like Wallpaper Engine's
      // own playback defaults.
      await player.setPlaylistMode(PlaylistMode.loop);
      await player.setVolume(0);
      // Started while the wallpaper is gated off (the window hidden, or a
      // fullscreen app over it): hold the first frame instead of decoding
      // into nothing.
      await player.open(Media(Uri.file(path).toString()),
          play: WallpaperGate.allowed.value);
    } catch (_) {
      // A file libmpv refuses simply shows nothing.
    }
  }

  void release() {
    _users--;
    if (_users > 0) return;
    _live.remove(path.toLowerCase());
    unawaited(player.dispose());
  }
}
