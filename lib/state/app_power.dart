import 'package:flutter/foundation.dart';

/// Whether the shell is running in its low-power profile.
///
/// The profile is a set of trades a handheld wants and a desktop does not: the
/// decorative motion goes, the eased readouts land instead of animating, the
/// scene wallpaper is capped at a lower rate and the wallpaper's blur is held
/// to what a low-power iGPU can raster. Every one of them is a *frame* cost, so
/// the whole profile is about how many frames the window asks for and what is
/// in them.
///
/// It lives here rather than on the settings object because the widgets that
/// follow it are the app's smallest ones — a telemetry readout, the opening
/// screen's own animation — and requiring a `SettingsProvider` above every one
/// of them would tie a leaf widget to the app's settings tree for a single
/// bool. [SettingsProvider] owns the decision (an explicit choice, or a battery
/// it heard about) and writes it here; the leaves read it.
///
/// Like [AppActivity] and `LiveSurfaces`, this is process-global state with a
/// plain default, so a test that mounts one of those leaves sees the profile
/// off unless it says otherwise.
class AppPower {
  AppPower._();

  /// True while the low-power profile is in force.
  static final ValueNotifier<bool> economy = ValueNotifier<bool>(false);

  static bool get isEconomy => economy.value;
}
