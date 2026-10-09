import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xgame_desktop/native/scene_pkg.dart';

import 'pkg_fixture.dart';

const _jpeg = [0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x01, 0x02, 0x03];

void main() {
  test('读取包表：名字、偏移与数据起点', () {
    final pkg = buildPackage([
      ('scene.json', Uint8List.fromList([1, 2, 3])),
      ('materials/back.tex', Uint8List.fromList([4, 5, 6, 7])),
    ]);
    final table = parseSceneTable(pkg)!;
    expect(table.entries.map((e) => e.name).toList(),
        ['scene.json', 'materials/back.tex']);
    expect(table.entries[0].offset, 0);
    expect(table.entries[0].length, 3);
    expect(table.entries[1].offset, 3);
    expect(table.entries[1].length, 4);
    expect(table.dataStart, greaterThan(0));
    expect(pkg.sublist(table.dataStart, table.dataStart + 3), [1, 2, 3]);
  });

  test('不是 Wallpaper Engine 包时返回空', () {
    expect(parseSceneTable(Uint8List.fromList(List.filled(64, 0x41))), isNull);
    expect(parseSceneTable(Uint8List.fromList([1, 2])), isNull);
  });

  test('解析纹理：尺寸、负载位置与类型', () {
    final blob = buildTexture(
        width: 3840, height: 2160, payload: _jpeg, format: 0);
    final texture = parseSceneTexture(blob, 'materials/back.tex')!;
    expect(texture.name, 'materials/back.tex');
    expect(texture.width, 3840);
    expect(texture.height, 2160);
    expect(texture.format, 0);
    expect(texture.lz4, isFalse);
    expect(texture.payloadKind, 'raw');
    expect(blob.sublist(texture.payloadOffset, texture.payloadOffset + 4),
        _jpeg.sublist(0, 4));
    expect(texture.payloadLength, _jpeg.length);
  });

  test('v2 容器的 LZ4 标记与解压长度', () {
    final blob = buildTexture(
        width: 2048,
        height: 2048,
        payload: List.filled(64, 7),
        version: 2,
        lz4: true,
        decompressed: 4096);
    final texture = parseSceneTexture(blob, 'materials/noise.tex')!;
    expect(texture.lz4, isTrue);
    expect(texture.decompressedLength, 4096);
    expect(texture.width, 2048);
  });

  test('v4 容器的额外字段（含条件字符串）不影响解析', () {
    final blob = buildTexture(
        width: 2560, height: 1440, payload: _jpeg, version: 4);
    final texture = parseSceneTexture(blob, 'materials/back.tex')!;
    expect(texture.width, 2560);
    expect(texture.height, 1440);
    expect(blob[texture.payloadOffset], 0xFF);
  });

  test('不是 TEXV 的负载返回空', () {
    expect(
        parseSceneTexture(
            Uint8List.fromList(List.filled(64, 0x42)), 'materials/x.tex'),
        isNull);
  });

  test('LZ4 块解压：字面量 + 回引', () {
    // One literal 'a', then a match of 9 bytes at offset 1 => 10 × 'a'.
    final source = Uint8List.fromList([0x15, 0x61, 0x01, 0x00]);
    final decoded = lz4BlockDecode(source, 10)!;
    expect(decoded, List.filled(10, 0x61));

    // Literals only.
    final literals = Uint8List.fromList([0x50, 1, 2, 3, 4, 5]);
    expect(lz4BlockDecode(literals, 5), [1, 2, 3, 4, 5]);

    // Truncated and mismatched-length inputs are rejected.
    expect(lz4BlockDecode(Uint8List.fromList([0x15, 0x61]), 10), isNull);
    expect(lz4BlockDecode(source, 11), isNull);
  });

  test('挑封面图：要横构图、够大，跳过遮罩/法线与竖图', () {
    SceneTexture tex(String name, int w, int h, {int format = 0}) =>
        SceneTexture(
          name: name,
          width: w,
          height: h,
          format: format,
          payloadOffset: 0,
          payloadLength: 16,
          lz4: false,
          decompressedLength: 0,
        );

    final list = [
      tex('materials/back_mask.tex', 3840, 2160), // mask
      tex('materials/water_normal.tex', 4096, 4096), // normal map
      tex('materials/portrait.tex', 1080, 1920), // portrait
      tex('materials/small.tex', 512, 288), // too small
      tex('materials/dxt.tex', 4096, 2304, format: 4), // DXT5, undecodable
      tex('materials/backdrop.tex', 2560, 1440),
      tex('materials/backdrop4k.tex', 3840, 2160),
    ];
    expect(pickBackdrop(list)!.name, 'materials/backdrop4k.tex');
    expect(pickBackdrop([tex('materials/only_dxt.tex', 3840, 2160, format: 4)]),
        isNull);
    expect(pickBackdrop([]), isNull);

    // No landscape picture in the package: a square 4K artwork still beats the
    // author's small preview, even though it is not shaped like a monitor.
    expect(
        pickBackdrop([
          tex('materials/art.tex', 2048, 2048),
          tex('materials/shake_mask.tex', 1024, 1024),
        ])!
            .name,
        'materials/art.tex');
    expect(pickBackdrop([tex('materials/portrait.tex', 1080, 1920)])!.name,
        'materials/portrait.tex');
    // Masks and normal maps never qualify, in either tier.
    expect(
        pickBackdrop([
          tex('materials/water_normal.tex', 4096, 4096),
          tex('materials/back_mask.tex', 3840, 2160),
        ]),
        isNull);
  });

  test('从包里取出原图：JPEG 负载原样落盘', () {
    final dir = Directory.systemTemp.createTempSync('xg_scene_pkg');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    // Real textures are megabytes; the reader skips dinky assets, so this one
    // is padded past that threshold (the payload is copied, not decoded).
    final payload = <int>[..._jpeg, ...List.filled(6000, 0x5A)];
    final texture = buildTexture(
        width: 3840, height: 2160, payload: payload, format: 0);
    final pkg = File('${dir.path}\\scene.pkg')
      ..writeAsBytesSync(buildPackage([
        ('scene.json', Uint8List.fromList([9, 9])),
        ('materials/back.tex', texture),
      ]));

    final written = extractSceneBackdrop(pkg.path, '${dir.path}\\out');
    expect(written, '${dir.path}\\out.jpg');
    expect(File(written!).readAsBytesSync(), payload);
  });

  test('取不出图时返回空（只有遮罩与竖图）', () {
    final dir = Directory.systemTemp.createTempSync('xg_scene_pkg2');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final mask = buildTexture(
        width: 1024, height: 1024, payload: List.filled(32, 3), format: 0);
    final pkg = File('${dir.path}\\scene.pkg')
      ..writeAsBytesSync(buildPackage([('materials/shake_mask.tex', mask)]));
    expect(extractSceneBackdrop(pkg.path, '${dir.path}\\out'), isNull);
    expect(File('${dir.path}\\out.png').existsSync(), isFalse);
  });

  test('原始 RGBA 负载编成 PNG：颜色保留，背景一律不透明', () {
    final dir = Directory.systemTemp.createTempSync('xg_scene_pkg3');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    // 1024×576 raw RGBA — landscape and big enough to be taken for the
    // backdrop. Every alpha byte is zero on purpose: a backdrop is opaque, and
    // the reader has always dropped alpha rather than showing a transparent
    // picture.
    const width = 1024;
    const height = 576;
    final payload = Uint8List(width * height * 4);
    for (var i = 0; i < width * height; i++) {
      payload[i * 4] = 0x10; // r
      payload[i * 4 + 1] = 0x20; // g
      payload[i * 4 + 2] = 0x30; // b
      payload[i * 4 + 3] = 0x00; // a — must come out as 255
    }
    final texture = buildTexture(
        width: width, height: height, payload: payload, format: 0);
    final pkg = File('${dir.path}\\scene.pkg')
      ..writeAsBytesSync(buildPackage([('materials/back.tex', texture)]));

    final written = extractSceneBackdrop(pkg.path, '${dir.path}\\out');
    expect(written, '${dir.path}\\out.png');
    final image = img.decodePng(File(written!).readAsBytesSync())!;
    expect(image.width, width);
    expect(image.height, height);
    final corner = image.getPixel(0, 0);
    expect(
        (
          corner.r.toInt(),
          corner.g.toInt(),
          corner.b.toInt(),
          corner.a.toInt()
        ),
        (0x10, 0x20, 0x30, 255));
    expect(image.getPixel(width - 1, height - 1).a.toInt(), 255);
  });
}
