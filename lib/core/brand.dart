/// The XGame mark, defined once, in fractions of the icon's edge (0..1).
///
/// Two things draw from these numbers — `lib/ui/brand_mark.dart` (the mark in
/// the window) and `tool/make_icon.dart` (which writes
/// `windows/runner/resources/app_icon.ico`) — so the app icon, the taskbar and
/// the title bar can never drift apart.
///
/// The mark is a diagonal D-pad: four chunky arms lit from above, crossing
/// under a bright centre disc that reads as the stick. The disc is what keeps
/// it from reading as a close button, and it keeps the 16 px frame legible.
///
/// Pure Dart on purpose: the generator runs on the plain VM, without Flutter,
/// so colors are kept as 0xRRGGBB ints.
class Brand {
  Brand._();

  /// The arms: two round-capped strokes.
  static const strokeWidth = 0.155;
  static const armInset = 0.315;
  static const bright = 0xB9AEFF;
  static const deep = 0x7460EC;

  /// Shadow cast by the upper stroke onto the lower one.
  static const shadowOffsetX = 0.010;
  static const shadowOffsetY = 0.020;
  static const shadowAlpha = 0.30;
  static const shadowRadius = 0.05;

  /// The centre disc, recessed into the crossing.
  static const discRadius = 0.098;
  static const discRingWidth = 0.022;
  static const discRingAlpha = 0.55;
  static const discTop = 0xEFEBFF;
  static const discBottom = 0xB0A2FF;

  /// The tile.
  static const tileRadius = 0.24;
  static const tileTop = 0x2A2350;
  static const tileBottom = 0x0E0B18;
  static const bloomColor = 0x8B7CFF;
  static const bloomAlpha = 0.26;
  static const bloomX = 0.30;
  static const bloomY = 0.24;
  static const bloomRadius = 0.92;
  static const rimWidth = 0.009;
  static const rimAlpha = 0.14;
}
