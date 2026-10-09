import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/core/brand.dart';
import 'package:xgame_desktop/ui/brand_mark.dart';

/// Paints the mark and reads the result back. A transparent or missing mark
/// (which is what a color without its alpha byte produces) fails here.
Future<ByteData> paintMark(
  WidgetTester tester,
  Widget mark, {
  int size = 64,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(width: size.toDouble(), height: size.toDouble(), child: mark),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
  image.dispose();
  return data;
}

({int r, int g, int b, int a}) pixel(ByteData data, int size, int x, int y) {
  final at = (y * size + x) * 4;
  return (
    r: data.getUint8(at),
    g: data.getUint8(at + 1),
    b: data.getUint8(at + 2),
    a: data.getUint8(at + 3),
  );
}

void main() {
  testWidgets('磁贴版图标真的被画出来：不透明、主色为紫', (tester) async {
    const size = 64;
    final data = await paintMark(tester, const BrandMark(size: 64, tile: true));

    // Tile corner (inside the rounded square) and the centre disc.
    for (final (x, y) in [(size ~/ 2, 6), (size ~/ 2, size ~/ 2)]) {
      final p = pixel(data, size, x, y);
      expect(p.a, 255, reason: '($x,$y) 必须是实心像素');
    }

    // An arm sample: violet means blue and red clearly above green.
    final arm = pixel(data, size, (size * 0.33).round(), (size * 0.6).round());
    expect(arm.a, 255);
    expect(arm.b, greaterThan(arm.g + 30), reason: '这一笔应当是紫色');
    expect(arm.r, greaterThan(arm.g), reason: '这一笔应当是紫色');

    // Outside the rounded corner stays transparent.
    expect(pixel(data, size, 1, 1).a, 0);
  });

  testWidgets('只画标记（标题栏那种）时不透明且带主色', (tester) async {
    const size = 64;
    final data = await paintMark(tester,
        const BrandMark(size: 64, color: Color(0xFFFFFFFF)));

    final arm = pixel(data, size, (size * 0.33).round(), (size * 0.33).round());
    expect(arm.a, 255);
    expect(arm.r, 255);
    expect(pixel(data, size, 0, 0).a, 0, reason: '角落留给底色');
  });

  test('几何常量自洽：笔画不越出磁贴', () {
    // Caps add half a stroke width past each end.
    final reach = Brand.armInset - Brand.strokeWidth / 2;
    expect(reach, greaterThan(0.15), reason: '标记四周要留出余量');
    expect(Brand.armInset * 2 + Brand.strokeWidth, lessThan(1.0));
    expect(Brand.discRadius, lessThan(Brand.strokeWidth),
        reason: '中心圆点不该宽过笔画');
  });
}
