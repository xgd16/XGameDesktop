import 'package:flutter/material.dart';

/// Telemetry numerals use Rajdhani — the squarish techno face is the
/// vernacular of game HUDs. Tabular figures keep digits from jittering
/// while values update once a second.
class TelemetryText {
  TelemetryText._();

  static const _digits = [
    FontFeature.tabularFigures(),
  ];

  /// The hero readout (CPU usage).
  static TextStyle hero(Color color) => TextStyle(
        fontFamily: 'Rajdhani',
        fontSize: 46,
        height: 1.0,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: color,
        fontFeatures: _digits,
      );

  /// Inline medium numerals (temps, speeds, VRAM).
  static TextStyle number(double size, Color color) => TextStyle(
        fontFamily: 'Rajdhani',
        fontSize: size,
        height: 1.05,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        color: color,
        fontFeatures: _digits,
      );

  static const label = TextStyle(
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
  );
}
