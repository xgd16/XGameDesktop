import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/brand.dart';

/// The XGame mark, drawn from [Brand] geometry.
///
/// With [tile] the full app icon is painted — the dark rounded tile, its
/// bloom, rim and the two-tone X — matching the generated .ico exactly. That
/// is what the settings page shows. Without it, just the X is painted in
/// [color], which is the title bar's brand chip.
///
/// [reveal] is the mark assembling itself, for the opening screen: 1 (the
/// default) is the finished icon, and below that the tile lands, the two arms
/// draw across it and the stick drops into the crossing. The schedule lives in
/// the painter, so a caller hands it a plain 0..1 progress.
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 14,
    this.color,
    this.tile = false,
    this.reveal = 1,
  });

  final double size;
  final Color? color;
  final bool tile;
  final double reveal;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      isComplex: true,
      painter: _BrandPainter(
        color: color ?? Colors.white,
        tile: tile,
        reveal: reveal,
      ),
    );
  }
}

class _BrandPainter extends CustomPainter {
  _BrandPainter({required this.color, required this.tile, this.reveal = 1});

  final Color color;
  final bool tile;
  final double reveal;

  /// [Brand] keeps colors as plain 0xRRGGBB so the icon generator can run
  /// without Flutter; here the opaque alpha byte goes back on. Without it
  /// every brand color would be fully transparent.
  static Color _c(int rgb, [double alpha = 1]) =>
      Color(0xFF000000 | rgb).withValues(alpha: alpha);

  /// How far [t] has come through the slice of the assembly that runs from
  /// [from] to [to].
  static double _stage(double t, double from, double to) =>
      ((t - from) / (to - from)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final box = Rect.fromLTWH(0, 0, s, s);
    final rrect = RRect.fromRectAndRadius(box, Radius.circular(s * Brand.tileRadius));

    // The assembly, in the order it happens: the tile lands first (a hair
    // under its size, so it settles rather than pops), the under-arm draws
    // itself across, the top arm follows over it, and the stick drops into the
    // crossing. At reveal 1 every stage is complete and the painting is
    // exactly the finished icon.
    final t = reveal.clamp(0.0, 1.0);
    final tileT = Curves.easeOutCubic.transform(_stage(t, 0.00, 0.26));
    final underT = Curves.easeInOutCubic.transform(_stage(t, 0.18, 0.58));
    final overT = Curves.easeInOutCubic.transform(_stage(t, 0.42, 0.82));
    final stickT = Curves.easeOutQuint.transform(_stage(t, 0.74, 1.00));

    // Everything stays inside the tile's silhouette, exactly like the
    // generator's alpha mask — the bloom would otherwise haze past the
    // rounded corners.
    if (tile) {
      canvas.save();
      canvas.clipRRect(rrect);
      final centre = Offset(s / 2, s / 2);
      final settle = 0.94 + 0.06 * tileT;
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.scale(settle);
      canvas.translate(-centre.dx, -centre.dy);
      _paintTile(canvas, box, rrect, s, tileT);
      canvas.restore();
    }

    final w = s * Brand.strokeWidth;
    final inset = s * Brand.armInset;
    // Stroke A runs top-left → bottom-right and lies on top of B.
    final a1 = Offset(inset, inset);
    final a2 = Offset(s - inset, s - inset);
    final b1 = Offset(s - inset, inset);
    final b2 = Offset(inset, s - inset);

    /// The part of `from → to` the arm has drawn, growing out of its top end.
    /// Nothing at all before the arm starts — a zero-length stroke still paints
    /// its round cap, and two caps sitting there read as a pair of eyes rather
    /// than the beginning of a stroke.
    Path drawn(Offset from, Offset to, double t) {
      final full = Path()
        ..moveTo(from.dx, from.dy)
        ..lineTo(to.dx, to.dy);
      if (t <= 0) return Path();
      if (t >= 1) return full;
      final length = (to - from).distance;
      return full.computeMetrics().first.extractPath(0, length * t);
    }

    if (!tile) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawPath(drawn(b1, b2, underT), paint);
      canvas.drawPath(drawn(a1, a2, overT), paint);
      return;
    }
    final shift = Offset(s * Brand.shadowOffsetX, s * Brand.shadowOffsetY);
    final over = drawn(a1, a2, overT);
    canvas.drawPath(
      over.shift(shift),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round
        ..color = Colors.black.withValues(alpha: Brand.shadowAlpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.026),
    );
    // Each arm keeps its own full-length gradient while it draws, so the
    // colour does not shift as the stroke grows.
    for (final (from, to, armT) in [(b1, b2, underT), (a1, a2, overT)]) {
      canvas.drawPath(
        drawn(from, to, armT),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(
            from,
            to,
            [_c(Brand.bright), _c(Brand.deep)],
          ),
      );
    }

    // The stick: a bright disc recessed into the crossing. It drops in from
    // well wide of its seat, fading up as it shrinks — which is what makes it
    // read as landing in the crossing rather than appearing in it.
    final centre = Offset(s / 2, s / 2);
    final disc = s * Brand.discRadius;
    final drop = 1.8 - 0.8 * stickT;
    canvas.drawCircle(
      centre,
      (disc + s * Brand.discRingWidth) * drop,
      Paint()..color = _c(Brand.tileBottom, Brand.discRingAlpha * stickT),
    );
    canvas.drawCircle(
      centre,
      disc * drop,
      Paint()
        ..shader = ui.Gradient.linear(
          centre.translate(-disc, -disc),
          centre.translate(disc, disc),
          [_c(Brand.discTop, stickT), _c(Brand.discBottom, stickT)],
        ),
    );
    canvas.restore();
  }

  void _paintTile(Canvas canvas, Rect box, RRect rrect, double s, double alpha) {
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = ui.Gradient.linear(
          box.topLeft,
          box.bottomRight,
          [_c(Brand.tileTop, alpha), _c(Brand.tileBottom, alpha)],
        ),
    );

    final centre = Offset(s * Brand.bloomX, s * Brand.bloomY);
    final bloom = s * Brand.bloomRadius;
    canvas.drawCircle(
      centre,
      bloom,
      Paint()
        ..shader = ui.Gradient.radial(centre, bloom, [
          _c(Brand.bloomColor, Brand.bloomAlpha * alpha),
          _c(Brand.bloomColor, 0),
        ]),
    );

    canvas.drawRRect(
      rrect.deflate(s * Brand.rimWidth / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * Brand.rimWidth
        ..color = Colors.white.withValues(alpha: Brand.rimAlpha * alpha),
    );
  }

  @override
  bool shouldRepaint(_BrandPainter old) =>
      old.tile != tile || old.color != color || old.reveal != reveal;
}
