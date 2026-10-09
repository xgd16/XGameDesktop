import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/clock_text.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/net/weather.dart';
import 'package:xgame_desktop/state/weather_provider.dart';
import 'package:xgame_desktop/ui/clock_weather.dart';

void main() {
  WeatherInfo reading({
    String city = '北京',
    double tempC = 24.4,
    int code = 1,
    bool isDay = true,
  }) =>
      WeatherInfo(
        city: city,
        tempC: tempC,
        code: code,
        isDay: isDay,
        tempMaxC: 28,
        tempMinC: 18,
        fetchedAt: DateTime(2026, 10, 3, 9, 5, 7),
      );

  Future<void> pumpPanel(WidgetTester tester, WeatherProvider provider) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<WeatherProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: const Scaffold(body: ClockWeatherPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('时刻与日期文本', () {
    final t = DateTime(2026, 10, 3, 9, 5, 7);
    expect(clockHm(t), '09:05');
    expect(clockSeconds(t), '07');
    expect(dateCn(t), '10月3日 星期六');
  });

  test('WMO 天气代码映射为中文描述', () {
    expect(conditionText(0), '晴');
    expect(conditionText(2), '多云');
    expect(conditionText(61), '小雨');
    expect(conditionText(95), '雷阵雨');
    expect(conditionText(1234), '未知');
  });

  test('定位结果解析：三家服务各写各的字段，失败响应要丢掉', () {
    final ipwho = WeatherClient.parseLocation(
        {'success': true, 'latitude': 39.9, 'longitude': 116.4, 'city': 'Beijing'});
    expect(ipwho?.lat, 39.9);
    expect(ipwho?.city, 'Beijing');

    final ipapi = WeatherClient.parseLocation(
        {'city': 'Beijing', 'latitude': 39.9, 'longitude': 116.4});
    expect(ipapi?.lon, 116.4);

    final ipApiCom = WeatherClient.parseLocation(
        {'status': 'success', 'city': 'Beijing', 'lat': 39.9, 'lon': 116.4});
    expect(ipApiCom?.lat, 39.9);

    expect(WeatherClient.parseLocation({'success': false, 'message': 'x'}), isNull);
    expect(WeatherClient.parseLocation({'status': 'fail', 'message': 'x'}), isNull);
    expect(WeatherClient.parseLocation({'error': true, 'reason': 'x'}), isNull);
    expect(WeatherClient.parseLocation({'success': true, 'city': 'Beijing'}), isNull);
  });

  test('Open-Meteo 响应解析', () {
    final info = WeatherClient.parseWeather({
      'current': {'temperature_2m': 23.6, 'is_day': 1, 'weather_code': 3},
      'daily': {
        'temperature_2m_max': [27.2],
        'temperature_2m_min': [17.8],
      },
    }, 'Beijing');
    expect(info, isNotNull);
    expect(info!.tempC, 23.6);
    expect(info.condition, '阴');
    expect(info.isDay, isTrue);
    expect(info.tempMaxC, 27.2);
    expect(info.tempMinC, 17.8);

    expect(WeatherClient.parseWeather({'current': {}}, 'x'), isNull);
  });

  test('刷新成功与失败的状态流转', () async {
    var calls = 0;
    final provider = WeatherProvider(fetch: () async {
      calls++;
      return reading();
    });
    await provider.refresh();
    expect(provider.status, WeatherStatus.ready);
    expect(provider.weather!.tempC, 24.4);
    expect(provider.error, isEmpty);
    expect(calls, 1);

    final failing =
        WeatherProvider(fetch: () async => throw const WeatherException('无法定位所在城市'));
    await failing.refresh();
    expect(failing.status, WeatherStatus.failed);
    expect(failing.error, '无法定位所在城市');
    expect(failing.weather, isNull);

    provider.dispose();
    failing.dispose();
  });

  testWidgets('面板显示时钟与当前天气', (tester) async {
    final provider = WeatherProvider(fetch: () async => reading());
    provider.now = DateTime(2026, 10, 3, 9, 5, 7);
    await provider.refresh();
    await pumpPanel(tester, provider);

    expect(find.text('09:05'), findsOneWidget);
    expect(find.text('07'), findsOneWidget);
    expect(find.text('10月3日 星期六'), findsOneWidget);
    expect(find.text('24°'), findsOneWidget);
    expect(find.text('晴间多云 · 北京'), findsOneWidget);
    expect(find.text('↑28°  ↓18°'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    provider.dispose();
  });

  testWidgets('天气不可用时给重试提示', (tester) async {
    final provider =
        WeatherProvider(fetch: () async => throw const WeatherException('定位失败'));
    await provider.refresh();
    await pumpPanel(tester, provider);

    expect(find.text('天气不可用'), findsOneWidget);
    expect(find.text('点击重试'), findsOneWidget);
    // The clock never depends on the network.
    expect(find.text(clockHm(provider.now)), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    provider.dispose();
  });
}
