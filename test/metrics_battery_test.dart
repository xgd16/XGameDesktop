import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/native/hwprobe_service.dart';
import 'package:xgame_desktop/state/weather_provider.dart';
import 'package:xgame_desktop/ui/metrics_panel.dart';

/// Ready without a backend. The readings the panel styles come from the
/// overridden getters: what is under test is the panel's contract with
/// "null = the machine cannot produce this reading", not the DLL's plumbing.
class _StubProbe extends HwprobeService {
  _StubProbe() {
    status = HwprobeStatus.ready;
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> shutdown() async {}

  double? chargePct;
  String? stateText;
  double? rateW;
  double? memPower;

  @override
  double? get batteryChargePct => chargePct;

  @override
  String? get batteryStateText => stateText;

  @override
  double? get batteryRateW => rateW;

  @override
  double? get memoryPowerW => memPower;
}

BatteryRef _fakeBattery() {
  return BatteryRef(
    name: 'Battery 0',
    chargePct: const SensorRef(5, 0, 0,
        code: 'charge_pct', name: 'Charge', unit: '%'),
    state: const SensorRef(5, 0, 1, code: 'state', name: 'State', unit: ''),
    rateMw: const SensorRef(5, 0, 2, code: 'rate_mw', name: 'Rate', unit: 'mW'),
    healthPct: 92.0,
    cycleCount: 213,
  );
}

Widget _host(HwprobeService service) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<HwprobeService>.value(value: service),
      ChangeNotifierProvider<WeatherProvider>(create: (_) => WeatherProvider()),
    ],
    child: MaterialApp(
      theme: buildTheme(appPalettes.first),
      home: const Scaffold(body: MetricsPanel()),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  testWidgets('带电池的设备显示电池区块，功率只显示幅值', (tester) async {
    final probe = _StubProbe()
      ..battery = _fakeBattery()
      ..chargePct = 76
      ..stateText = '充电中'
      ..rateW = 8.2;
    await tester.pumpWidget(_host(probe));
    await _settle(tester);

    expect(find.text('电池'), findsOneWidget);
    expect(find.text('状态'), findsOneWidget);
    expect(find.text('充电中'), findsOneWidget);
    expect(find.text('健康'), findsOneWidget);
    // 充放电方向由状态一栏说，功率不再带 +/-。
    expect(find.text('8.2W'), findsOneWidget);
    expect(find.text('+8.2W'), findsNothing);
    expect(find.text('-8.2W'), findsNothing);
    // 电池区块插入在内存与网络之间。
    expect(find.text('网络'), findsOneWidget);
  });

  testWidgets('放电同样只显示幅值，不带负号', (tester) async {
    final probe = _StubProbe()
      ..battery = _fakeBattery()
      ..chargePct = 40
      ..stateText = '放电中'
      ..rateW = -12.4;
    await tester.pumpWidget(_host(probe));
    await _settle(tester);

    expect(find.text('放电中'), findsOneWidget);
    expect(find.text('12W'), findsOneWidget);
    expect(find.text('-12W'), findsNothing);
    expect(find.text('-12.4W'), findsNothing);
  });

  testWidgets('功率读不到时功率一项整个不出现', (tester) async {
    final probe = _StubProbe()
      ..battery = _fakeBattery()
      ..chargePct = 76
      ..stateText = '充电中';
    await tester.pumpWidget(_host(probe));
    await _settle(tester);

    expect(find.text('状态'), findsOneWidget);
    expect(find.text('功率'), findsNothing);
  });

  testWidgets('无电池的设备不显示电池区块', (tester) async {
    await tester.pumpWidget(_host(_StubProbe()));
    await _settle(tester);

    expect(find.text('电池'), findsNothing);
    // 其余区块不受影响。
    expect(find.text('处理器'), findsOneWidget);
    expect(find.text('网络'), findsOneWidget);
  });

  testWidgets('内存功耗读不到时功耗一项不出现', (tester) async {
    await tester.pumpWidget(_host(_StubProbe()));
    await _settle(tester);

    expect(find.text('内存'), findsOneWidget);
    expect(find.text('功耗'), findsNothing);
  });

  testWidgets('内存功耗读得到时才显示功耗', (tester) async {
    final probe = _StubProbe()..memPower = 3.4;
    await tester.pumpWidget(_host(probe));
    await _settle(tester);

    expect(find.text('功耗'), findsOneWidget);
    expect(find.text('3.4W'), findsOneWidget);
  });
}
