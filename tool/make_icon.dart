// Rasterises the XGame mark (lib/core/brand.dart) into the Windows icon the
// runner embeds, plus an optional preview sheet.
//
//   dart run tool/make_icon.dart [out.ico] [--png preview.png] [--scale 4]
//
// Every size is drawn from the same signed-distance description at `scale`
// times the target resolution and then averaged down, which is what keeps the
// 16 px frame from turning to mush.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:xgame_desktop/core/brand.dart';

const _sizes = [16, 24, 32, 48, 64, 128, 256];

void main(List<String> args) {
  final out = args.firstWhere(
    (a) => !a.startsWith('--'),
    orElse: () => 'windows/runner/resources/app_icon.ico',
  );
  final png = _flag(args, '--png');
  final scale = int.tryParse(_flag(args, '--scale') ?? '') ?? 4;

  final watch = Stopwatch()..start();
  final frames = [for (final size in _sizes) _render(size, scale)];
  final ico = img.Image(width: frames.first.width, height: frames.first.height, numChannels: 4);
  for (final frame in frames) {
    ico.addFrame(frame);
  }
  final bytes = img.encodeIco(ico);
  File(out).writeAsBytesSync(bytes);
  print('wrote $out (${bytes.length} bytes, '
      '${_sizes.join('/')}) in ${watch.elapsedMilliseconds} ms');

  if (png != null) {
    File(png).writeAsBytesSync(img.encodePng(_sheet(frames)));
    print('wrote $png');
  }
}

String? _flag(List<String> args, String name) {
  final at = args.indexOf(name);
  if (at < 0 || at + 1 >= args.length) return null;
  return args[at + 1];
}

/// One frame: draw at `size * scale`, then average down. RGB is computed even
/// where the tile is transparent — averaging black into the rounded corners
/// would leave a dark fringe.
img.Image _render(int size, int scale) {
  final n = size * scale;
  final big = img.Image(width: n, height: n, numChannels: 4);
  final aa = 1.4 / n;
  for (var y = 0; y < n; y++) {
    final v = (y + 0.5) / n;
    for (var x = 0; x < n; x++) {
      final sh = _shade((x + 0.5) / n, v, aa);
      big.setPixelRgba(
          x, y, _b(sh.r), _b(sh.g), _b(sh.b), _b(sh.a));
    }
  }
  return img.copyResize(big,
      width: size, height: size, interpolation: img.Interpolation.average);
}

int _b(double v) => (v * 255).round().clamp(0, 255);

/// A preview sheet: every size at 1:1 over dark and light, then the small ones
/// at 3× to inspect the joins.
img.Image _sheet(List<img.Image> frames) {
  const pad = 20;
  const gap = 14;
  final small = frames.where((f) => f.width <= 64).toList();
  final row1 = frames.fold<int>(0, (a, f) => a + f.width + gap);
  final row3 = small.fold<int>(0, (a, f) => a + f.width * 3 + gap);
  final zoomBand = small.last.width * 3 + 40;
  final sheet = img.Image(
      width: math.max(row1, row3) + pad,
      height: 256 + 48 + zoomBand + pad * 2,
      numChannels: 3);
  img.fill(sheet, color: img.ColorRgb8(16, 16, 22));

  var x = pad;
  for (final f in frames) {
    img.compositeImage(sheet, f, dstX: x, dstY: pad + (256 - f.height) ~/ 2);
    x += f.width + gap;
  }

  // The same row on a light background.
  final lightTop = pad + 256 + 8;
  img.fillRect(sheet,
      x1: pad ~/ 2,
      y1: lightTop - 4,
      x2: sheet.width - pad ~/ 2,
      y2: lightTop + 48,
      color: img.ColorRgb8(232, 232, 238));
  x = pad;
  for (final f in small) {
    img.compositeImage(sheet, f,
        dstX: x, dstY: lightTop + (44 - f.height) ~/ 2);
    x += f.width + gap;
  }

  // 3× blow-ups of the small frames.
  x = pad;
  final zoomTop = lightTop + 52;
  for (final f in small) {
    final big = img.copyResize(f,
        width: f.width * 3,
        height: f.width * 3,
        interpolation: img.Interpolation.average);
    img.compositeImage(sheet, big,
        dstX: x, dstY: zoomTop + (zoomBand - big.height) ~/ 2);
    x += big.width + gap;
  }
  return sheet;
}

class _Shade {
  const _Shade(this.r, this.g, this.b, this.a);
  final double r, g, b, a;
}

/// Composites the tile, its bloom and rim, the woven X and the glint at one
/// sample point. Distances are in fractions of the icon edge.
_Shade _shade(double u, double v, double aa) {
  final cover = _clamp01(0.5 - _sdTile(u, v) / aa);

  final t = (u + v) / 2;
  var r = _lerp(_r(Brand.tileTop), _r(Brand.tileBottom), t);
  var g = _lerp(_g(Brand.tileTop), _g(Brand.tileBottom), t);
  var b = _lerp(_b8(Brand.tileTop), _b8(Brand.tileBottom), t);

  // Bloom in the upper left, to stop the tile reading as a flat swatch.
  final bd = _dist(u, v, Brand.bloomX, Brand.bloomY) / Brand.bloomRadius;
  final bloom = _clamp01(1 - bd);
  if (bloom > 0) {
    final a = Brand.bloomAlpha * bloom * bloom;
    r = _over(_r(Brand.bloomColor), a, r);
    g = _over(_g(Brand.bloomColor), a, g);
    b = _over(_b8(Brand.bloomColor), a, b);
  }

  // Hairline rim just inside the tile edge.
  final rim = _clamp01((Brand.rimWidth / 2 - _sdTile(u, v).abs()) / aa + 0.5);
  if (rim > 0) {
    final a = Brand.rimAlpha * rim;
    r = _over(1, a, r);
    g = _over(1, a, g);
    b = _over(1, a, b);
  }

  final w = Brand.strokeWidth / 2;
  final i = Brand.armInset;
  final (da, ta) = _sdSegment(u, v, i, i, 1 - i, 1 - i);
  final (db, tb) = _sdSegment(u, v, 1 - i, i, i, 1 - i);

  // Shadow under the top stroke: the X reads as two bars crossing.
  final (ds, _) = _sdSegment(u, v, i + Brand.shadowOffsetX, i + Brand.shadowOffsetY,
      1 - i + Brand.shadowOffsetX, 1 - i + Brand.shadowOffsetY);
  final sd = _clamp01(1 - ds / Brand.shadowRadius);
  if (sd > 0) {
    final a = Brand.shadowAlpha * sd * sd;
    r = _over(0, a, r);
    g = _over(0, a, g);
    b = _over(0, a, b);
  }

  final cb = _clamp01((w - db) / aa + 0.5);
  if (cb > 0) {
    r = _over(_lerp(_r(Brand.bright), _r(Brand.deep), tb), cb, r);
    g = _over(_lerp(_g(Brand.bright), _g(Brand.deep), tb), cb, g);
    b = _over(_lerp(_b8(Brand.bright), _b8(Brand.deep), tb), cb, b);
  }

  final ca = _clamp01((w - da) / aa + 0.5);
  if (ca > 0) {
    r = _over(_lerp(_r(Brand.bright), _r(Brand.deep), ta), ca, r);
    g = _over(_lerp(_g(Brand.bright), _g(Brand.deep), ta), ca, g);
    b = _over(_lerp(_b8(Brand.bright), _b8(Brand.deep), ta), ca, b);
  }

  // The stick: a bright disc recessed into the crossing.
  final dd = _dist(u, v, 0.5, 0.5);
  final ring = _clamp01((Brand.discRingWidth - (dd - Brand.discRadius).abs()) / aa + 0.5);
  if (ring > 0) {
    final a = Brand.discRingAlpha * ring;
    r = _over(_r(Brand.tileBottom), a, r);
    g = _over(_g(Brand.tileBottom), a, g);
    b = _over(_b8(Brand.tileBottom), a, b);
  }
  final disc = _clamp01((Brand.discRadius - dd) / aa + 0.5);
  if (disc > 0) {
    final t = ((u - 0.5) + (v - 0.5)) / 2 / Brand.discRadius * 0.5 + 0.5;
    r = _over(_lerp(_r(Brand.discTop), _r(Brand.discBottom), t), disc, r);
    g = _over(_lerp(_g(Brand.discTop), _g(Brand.discBottom), t), disc, g);
    b = _over(_lerp(_b8(Brand.discTop), _b8(Brand.discBottom), t), disc, b);
  }

  return _Shade(r, g, b, cover);
}

/// Distance to the tile's rounded square edge (negative inside).
double _sdTile(double u, double v) {
  const half = 0.5;
  const r = Brand.tileRadius;
  final qx = (u - 0.5).abs() - (half - r);
  final qy = (v - 0.5).abs() - (half - r);
  final ax = math.max(qx, 0.0);
  final ay = math.max(qy, 0.0);
  return math.sqrt(ax * ax + ay * ay) + math.min(math.max(qx, qy), 0.0) - r;
}

/// Distance to a segment, and where along it the closest point sits (0..1).
(double, double) _sdSegment(
    double px, double py, double ax, double ay, double bx, double by) {
  final dx = bx - ax;
  final dy = by - ay;
  final len2 = dx * dx + dy * dy;
  final t = len2 == 0
      ? 0.0
      : (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
  final cx = ax + dx * t;
  final cy = ay + dy * t;
  return (math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy)), t);
}

double _dist(double ax, double ay, double bx, double by) =>
    math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

double _clamp01(double v) => v.clamp(0.0, 1.0);

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _over(double src, double alpha, double dst) =>
    src * alpha + dst * (1 - alpha);

double _r(int rgb) => ((rgb >> 16) & 0xFF) / 255;
double _g(int rgb) => ((rgb >> 8) & 0xFF) / 255;
double _b8(int rgb) => (rgb & 0xFF) / 255;
