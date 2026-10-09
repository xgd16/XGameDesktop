import 'package:flutter/widgets.dart';

/// Whether the app's window is on screen.
///
/// Every recurring job that costs real CPU hangs off this: the telemetry poll,
/// the pad poll, video decoding, the clock tick. A minimized launcher has
/// nothing to show, and a wallpaper is not worth a decode nobody can see.
///
/// Desktop lifecycle reports exactly what is needed here: the Windows embedder
/// sends `hidden` when the window is minimized or hidden, `inactive` when it is
/// merely unfocused (still visible — nothing may pause), and `resumed` when it
/// is back in front. Input that must not fire while another window is in front
/// does *not* hang off this — see `GamepadService`, which asks Windows for the
/// foreground window instead: this app's runner swallows WM_ACTIVATE, so
/// `inactive` cannot be relied on to arrive.
///
/// Tests never feed it, so everything keeps running there.
class AppActivity {
  AppActivity._();

  /// True while the window is visible. Listeners are called on change, which is
  /// also the resume/suspend signal for the services that can stop and start.
  static final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  static bool get isVisible => visible.value;

  /// Feeds a lifecycle state in. Anything but hidden/paused counts as visible.
  static void update(AppLifecycleState state) {
    final next = state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused;
    visible.value = next;
  }
}
