import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/native/hwprobe_service.dart';
import 'package:xgame_desktop/state/weather_provider.dart';
import 'package:xgame_desktop/ui/metrics_panel.dart';

class _QuietProbe extends HwprobeService {
  @override
  Future<void> start() async {}

  @override
  Future<void> shutdown() async {}
}

FanRef _fan(String device, String sensorName) {
  return FanRef(
    device: device,
    sensorName: sensorName,
    ref: SensorRef(2, 0, 15, code: 'fan_rpm', name: sensorName, unit: 'RPM'),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<HwprobeService>.value(value: _probe),
      ChangeNotifierProvider<WeatherProvider>(create: (_) => WeatherProvider()),
    ],
    child: MaterialApp(
      theme: buildTheme(appPalettes.first),
      home: const Scaffold(body: MetricsPanel()),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

late HwprobeService _probe;

void main() {
  setUp(() {
    _probe = _QuietProbe()..status = HwprobeStatus.ready;
  });

  testWidgets('有风扇读数时出现风扇区块，按传感器命名', (tester) async {
    _probe.fans = [_fan('AMD Radeon RX 6800 XT', 'Fan')];
    await _settle(tester);

    // 区块标题 + 唯一的行标签：只有一个风扇时行就叫"风扇"，不需要设备名消歧。
    expect(find.text('风扇'), findsNWidgets(2));
    expect(find.text('风扇 · AMD Radeon RX 6800 XT'), findsNothing);
    // 读数还没进来（没有轮询），行不至于缺位，值退成 '--'。
    expect(find.text('--'), findsWidgets);
  });

  testWidgets('多设备都叫 Fan 时用设备名消歧', (tester) async {
    _probe.fans = [
      _fan('AMD Radeon RX 6800 XT', 'Fan'),
      _fan('iGame Z490 Vulcan X', 'Fan'),
    ];
    await _settle(tester);

    // 行标签都带了设备名，只剩区块标题自己叫"风扇"。
    expect(find.text('风扇'), findsOneWidget);
    expect(find.text('风扇 · AMD Radeon RX 6800 XT'), findsOneWidget);
    expect(find.text('风扇 · iGame Z490 Vulcan X'), findsOneWidget);
  });

  testWidgets('名字有区分度的传感器直接用原名', (tester) async {
    _probe.fans = [_fan('iGame Z490 Vulcan X', 'CPU Fan')];
    await _settle(tester);

    expect(find.text('CPU Fan'), findsOneWidget);
    expect(find.text('风扇 · iGame Z490 Vulcan X'), findsNothing);
  });

  testWidgets('没有风扇数据的机器不显示风扇区块', (tester) async {
    await _settle(tester);

    expect(find.text('风扇'), findsNothing);
    // 其余区块不受影响。
    expect(find.text('处理器'), findsOneWidget);
    expect(find.text('内存'), findsOneWidget);
  });

  testWidgets('空插针和没有测速线的风扇不占行，转过的才留', (tester) async {
    _probe.fans = [
      _fan('iGame Z490 Vulcan X', 'Fan #0'),
      _fan('iGame Z490 Vulcan X', 'Fan #1'),
      _fan('iGame Z490 Vulcan X', 'Fan #2'),
    ];
    // 主板给每个插针都编号，可 #0 一直报 0（空插针）、#1 从来报不出数
    // （没有测速线），只有 #2 真的在转。
    _probe.sampleFans([0, null, 1538]);
    await _settle(tester);

    expect(find.text('风扇 2'), findsOneWidget);
    expect(find.text('1538 RPM'), findsOneWidget);
    expect(find.text('风扇 0'), findsNothing);
    expect(find.text('风扇 1'), findsNothing);
    expect(find.text('0 RPM'), findsNothing);
  });

  testWidgets('全部风扇都没转过时，风扇区块整个不出现', (tester) async {
    _probe.fans = [
      _fan('iGame Z490 Vulcan X', 'Fan #0'),
      _fan('iGame Z490 Vulcan X', 'Fan #1'),
    ];
    _probe.sampleFans([0, null]);
    await _settle(tester);

    expect(find.text('风扇'), findsNothing);
  });

  testWidgets('读数时有时无时行不跟着闪，值按最后报上来的留着', (tester) async {
    _probe.fans = [_fan('iGame Z490 Vulcan X', 'CPU Fan')];
    _probe.sampleFans([1200]);
    _probe.sampleFans([null]);
    _probe.sampleFans([null]);
    await _settle(tester);

    expect(find.text('CPU Fan'), findsOneWidget);
    // 值是最后报上来的那个，不是退化成 '--'——行里只有这一行文本。
    expect(find.text('1200 RPM'), findsOneWidget);
  });

  testWidgets('转过又停下的风扇显示「停转」，不是 0 RPM', (tester) async {
    _probe.fans = [_fan('AMD Radeon RX 6800 XT', 'Fan')];
    _probe.sampleFans([1538]);
    _probe.sampleFans([0]);
    await _settle(tester);

    expect(find.text('停转'), findsOneWidget);
    expect(find.text('0 RPM'), findsNothing);
    // 行还在：它转过，0 是停下，不是消失。
    expect(find.text('风扇'), findsNWidgets(2));
  });
}
