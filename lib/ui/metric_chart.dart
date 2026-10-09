import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';

/// One line on a chart: what it is called, the colour it is drawn in, and one
/// value per bucket of the window the chart covers.
///
/// A null is a bucket the machine reported nothing for — the driver is not
/// installed, the sensor is missing, the app was closed across it — and the
/// line breaks there rather than being drawn straight through a gap that never
/// had a reading in it.
class MetricSeries {
  const MetricSeries({
    required this.label,
    required this.color,
    required this.values,
  });

  final String label;
  final Color color;
  final List<double?> values;
}

/// The line chart the monitoring page is made of: one or two series over a
/// window of time, a flat translucent fill underneath when there is only one
/// of them, three hairline gridlines, and the axis labels a person needs to
/// read a shape — the top of the scale, and when the window starts, turns and
/// ends. No gradient, no animation, no tooltips: it is the same drawing style
/// as the telemetry panel's sparkline, at page size.
class MetricChart extends StatelessWidget {
  const MetricChart({
    super.key,
    required this.series,
    required this.times,
    this.ceiling,
    this.decimals = 1,
    this.height = 124,
  });

  final List<MetricSeries> series;

  /// One moment per bucket, shared by every series — the chart's x axis.
  final List<DateTime> times;

  /// The value the axis tops out at, when the reading has a natural maximum
  /// (a percentage). Null autoscales to the data.
  final double? ceiling;

  /// Decimals in the axis labels.
  final int decimals;

  final double height;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _MetricChartPainter(
          series: series,
          times: times,
          ceiling: ceiling,
          decimals: decimals,
          grid: c.border,
          label: c.textMuted,
        ),
      ),
    );
  }
}

class _MetricChartPainter extends CustomPainter {
  _MetricChartPainter({
    required this.series,
    required this.times,
    required this.ceiling,
    required this.decimals,
    required this.grid,
    required this.label,
  });

  final List<MetricSeries> series;
  final List<DateTime> times;
  final double? ceiling;
  final int decimals;
  final Color grid;
  final Color label;

  /// Room for the axis labels down the left and under the plot.
  static const double _gutterLeft = 44;
  static const double _gutterBottom = 17;
  static const double _gutterTop = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      _gutterLeft,
      _gutterTop,
      size.width,
      size.height - _gutterBottom,
    );
    if (plot.width <= 12 || plot.height <= 12) return;
    final count = times.length;
    if (count == 0) return;

    final top = _axisTop();
    double y(double value) =>
        plot.bottom - (value / top).clamp(0.0, 1.0) * plot.height;
    final step = count == 1 ? 0.0 : plot.width / (count - 1);
    double x(int index) => plot.left + step * index;

    // Three gridlines, and the scale they stand for: the bottom one is zero,
    // which is what makes a curve's height mean anything.
    final hairline = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final value = top * i / 2;
      final lineY = y(value);
      canvas.drawLine(Offset(plot.left, lineY), Offset(plot.right, lineY),
          hairline);
      final painter = _text(_axisLabel(value));
      painter.paint(
        canvas,
        Offset(plot.left - 7 - painter.width, lineY - painter.height / 2),
      );
    }

    _paintTimes(canvas, plot);

    for (final line in series) {
      if (line.values.length != count) continue;
      final points = <Offset?>[
        for (var i = 0; i < count; i++)
          line.values[i] == null ? null : Offset(x(i), y(line.values[i]!)),
      ];
      if (line.values.where((value) => value != null).length < 2) continue;

      // One series gets the filled area under it; two would draw mud where
      // the fills overlap, so they stay lines.
      if (series.length == 1) {
        canvas.drawPath(
          _area(points, plot.bottom),
          Paint()..color = line.color.withValues(alpha: 0.12),
        );
      }
      canvas.drawPath(
        _path(points),
        Paint()
          ..color = line.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      // The newest reading, marked: the eye finds "now" on the right edge.
      Offset? last;
      for (final point in points) {
        if (point != null) last = point;
      }
      if (last != null) {
        canvas.drawCircle(last, 2.2, Paint()..color = line.color);
      }
    }
  }

  /// The moments under the plot: the window's start, its middle and its end —
  /// enough to tell which way time runs and how wide it is. A window with only
  /// a bucket or two collapses to fewer marks rather than stamping the same
  /// label three times.
  void _paintTimes(Canvas canvas, Rect plot) {
    final count = times.length;
    final span = times.last.difference(times.first);
    final marks = <int, double>{
      0: 0.0,
      (count - 1) ~/ 2: 0.5,
      count - 1: 1.0,
    };
    for (final entry in marks.entries) {
      final painter = _text(_clock(times[entry.key], span));
      final cx =
          plot.left + plot.width * entry.value - painter.width * entry.value;
      painter.paint(canvas, Offset(cx, plot.bottom + 5));
    }
  }

  static Path _path(List<Offset?> points) {
    final path = Path();
    var open = false;
    for (final point in points) {
      if (point == null) {
        open = false;
        continue;
      }
      if (open) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
      }
      open = true;
    }
    return path;
  }

  /// The fill under the line, one closed run per stretch without a gap.
  static Path _area(List<Offset?> points, double baseline) {
    final path = Path();
    var run = <Offset>[];
    void closeRun() {
      if (run.length >= 2) {
        path.moveTo(run.first.dx, baseline);
        for (final point in run) {
          path.lineTo(point.dx, point.dy);
        }
        path
          ..lineTo(run.last.dx, baseline)
          ..close();
      }
      run = [];
    }

    for (final point in points) {
      if (point == null) {
        closeRun();
      } else {
        run.add(point);
      }
    }
    closeRun();
    return path;
  }

  double _axisTop() {
    final fixed = ceiling;
    if (fixed != null) return fixed;
    var max = 0.0;
    for (final line in series) {
      for (final value in line.values) {
        if (value != null && value > max) max = value;
      }
    }
    if (max <= 0) return 1;
    // 1, 2 or 5 times a power of ten: an axis whose top label is a number
    // somebody reads at a glance rather than one the data happened to reach.
    final magnitude =
        math.pow(10, (math.log(max) / math.ln10).floor()).toDouble();
    for (final step in const [1.0, 2.0, 5.0]) {
      if (max <= step * magnitude) return step * magnitude;
    }
    return 10 * magnitude;
  }

  /// How a moment is written when the window is [span] wide: clock time for a
  /// window inside a day, the date as well for a longer one.
  static String _clock(DateTime time, Duration span) {
    final local = time.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    if (span.inHours < 24) return '$hh:$mm';
    return '${local.month}/${local.day} $hh:$mm';
  }

  /// An axis label, compressed once it runs past four digits: a disk or a
  /// network rate is collected in KB/s and can reach six figures, and the
  /// gutter is 44 px wide. The card's legend carries the unit.
  String _axisLabel(double value) {
    final abs = value.abs();
    if (abs >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (abs >= 10000) return '${(value / 1000).toStringAsFixed(0)}k';
    return value.toStringAsFixed(decimals);
  }

  TextPainter _text(String value) => TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(fontSize: 10, color: label),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  bool shouldRepaint(_MetricChartPainter old) =>
      old.ceiling != ceiling ||
      old.decimals != decimals ||
      old.grid != grid ||
      old.label != label ||
      // By value, not by identity: the page hands in fresh lists on every
      // collection, and identity comparison would repaint the whole grid
      // every few seconds whether the curves moved or not.
      !_sameSeries(old.series, series) ||
      !listEquals(old.times, times);

  static bool _sameSeries(List<MetricSeries> a, List<MetricSeries> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].label != b[i].label || a[i].color != b[i].color) return false;
      if (!listEquals(a[i].values, b[i].values)) return false;
    }
    return true;
  }
}
