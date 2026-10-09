import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/state/background_glass.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/ui/background_layer.dart';

/// 静态壁纸是唯一烘得起的一份背景：整幅连同填充、暗化一起糊一次，缩到一半
/// 存进 BackgroundGlass，桌面上的面板取样它自己的那一块。动态壁纸背后会动，
/// 面板没有可取的静图，仍旧实时回读——这些用例盯的就是这条分界。
void main() {
  late Directory dataDir;
  late File picture;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_bake');
    picture = File('${dataDir.path}\\wall.png')
      ..writeAsBytesSync(_png(width: 24, height: 16));
  });

  tearDown(() {
    BackgroundGlass.clear();
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A provider over the temp data dir, released with the test: it holds the
  /// profile database open, and Windows will not delete the directory until it
  /// lets go.
  SettingsProvider tracked() {
    final settings = SettingsProvider(dataDir: dataDir);
    addTearDown(settings.dispose);
    return settings;
  }

  Future<void> mount(WidgetTester tester, SettingsProvider settings,
      {bool card = false}) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(
            body: card
                ? const AppBackground(sceneStill: true)
                : const AppBackground(),
          ),
        ),
      ),
    );
  }

  /// 烘焙先等一拍（图片解码是异步的），再让 toImage 的真实异步跑完。
  Future<void> settleBake(WidgetTester tester, {int cycles = 8}) async {
    for (var i = 0; i < cycles; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
    }
    await tester.pump();
  }

  testWidgets('静态壁纸烘出一份缩小、预先糊好的副本', (tester) async {
    final settings = tracked()
      ..backgroundPath = picture.path;
    await mount(tester, settings);
    await settleBake(tester);

    final glass = BackgroundGlass.current.value;
    expect(glass, isNotNull, reason: '静态壁纸应当烘出可取样的副本');
    expect(glass!.sigma, BackgroundGlass.frostSigma,
        reason: '烘的就是面板默认要的那个模糊度');
    expect(
      glass.pixelsPerLogical,
      moreOrLessEquals(0.5 * tester.view.devicePixelRatio, epsilon: 0.001),
      reason: '半分辨率：这么宽的模糊没有细节可丢',
    );

    // 副本里装的是那张图：中心像素带着暗化后的壁纸颜色，而不是纯主题底。
    final data = await tester.runAsync(() => glass.image.toByteData());
    final bytes = data!.buffer.asUint8List();
    final center = ((glass.image.height ~/ 2) * glass.image.width +
            glass.image.width ~/ 2) *
        4;
    expect(bytes[center], greaterThan(40), reason: '主题底只有十几，这里应当是红图');
    expect(bytes[center], greaterThan(bytes[center + 1] + 15));
  });

  testWidgets('静态壁纸挂的是视频时不烘，面板继续实时回读', (tester) async {
    final settings = tracked()
      ..backgroundPath = picture.path
      ..backgroundSource = BackgroundSource.video;
    await mount(tester, settings);
    await settleBake(tester);

    expect(BackgroundGlass.current.value, isNull);
  });

  testWidgets('设置页里的预览卡不替窗口烘背景', (tester) async {
    final settings = tracked()
      ..backgroundPath = picture.path;
    await mount(tester, settings, card: true);
    await settleBake(tester);

    expect(BackgroundGlass.current.value, isNull,
        reason: '卡片画的是缩略图，取样它会把面板的玻璃算错');
  });

  testWidgets('壁纸撤掉后副本作废', (tester) async {
    final settings = tracked()
      ..backgroundPath = picture.path;
    await mount(tester, settings);
    await settleBake(tester);
    expect(BackgroundGlass.current.value, isNotNull);

    settings.clearBackground();
    await tester.pump();

    expect(BackgroundGlass.current.value, isNull);
  });

  /// 会动的图没有"静"可言：烘出来的副本只会僵在它被拍下的那一帧。
  testWidgets('多帧的动图不烘，面板保持实时回读', (tester) async {
    final animation = File('${dataDir.path}\\anim.gif')
      ..writeAsBytesSync(_animatedGif());
    final settings = tracked()
      ..backgroundPath = animation.path;
    await mount(tester, settings);
    // 帧要按真实时间推进，动图才会自己暴露出来。
    await settleBake(tester, cycles: 12);

    expect(BackgroundGlass.current.value, isNull);
  });
}

/// 一张真图，让解码、合成和烘焙都走真实路径。
List<int> _png({required int width, required int height}) =>
    img.encodePng(img.Image(width: width, height: height)
      ..clear(img.ColorRgb8(180, 60, 90)));

/// 两帧的 GIF。
List<int> _animatedGif() {
  final image = img.Image(width: 16, height: 16)
    ..clear(img.ColorRgb8(220, 60, 90));
  image.addFrame().clear(img.ColorRgb8(20, 60, 90));
  for (final frame in image.frames) {
    frame.frameDuration = 40;
  }
  return img.encodeGif(image);
}
