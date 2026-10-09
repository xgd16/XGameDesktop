import 'package:flutter/animation.dart';

/// Central motion vocabulary. Non-user-triggered motion is limited to the
/// single boot-up sequence — the opening screen assembling the mark, its field
/// splitting away, and the grid's one wave — everything else answers an action
/// or shows live data changing.
class Motion {
  Motion._();

  static const fast = Duration(milliseconds: 150);
  static const base = Duration(milliseconds: 250);
  static const slow = Duration(milliseconds: 400);
  static const theme = Duration(milliseconds: 350);

  /// The opening screen: the mark draws itself, holds a beat once the load is
  /// done (so a full hairline is read, not blinked past), then the field
  /// splits along the mark's arms and flies to the corners.
  static const bootIntro = Duration(milliseconds: 1050);
  static const bootHold = Duration(milliseconds: 260);
  static const bootExit = Duration(milliseconds: 460);

  /// Interval between staggered entrance steps.
  static const staggerStep = Duration(milliseconds: 18);
  static const maxStagger = Duration(milliseconds: 720);

  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const outCubic = Cubic(0.215, 0.61, 0.355, 1.0);
  static const outQuint = Cubic(0.22, 1.0, 0.36, 1.0);

  /// The out* family lands; this one is for motion that is *seen* travel — the
  /// boot screen's field leaving the window — where a fast start would read as
  /// a cut instead of a departure.
  static const inOutCubic = Cubic(0.645, 0.045, 0.355, 1.0);

  static Duration staggerDelay(int index) {
    final step = staggerStep * index;
    return step > maxStagger ? maxStagger : step;
  }
}
