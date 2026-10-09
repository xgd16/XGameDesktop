import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One current-conditions reading for the machine's approximate location.
class WeatherInfo {
  const WeatherInfo({
    required this.city,
    required this.tempC,
    required this.code,
    required this.isDay,
    required this.fetchedAt,
    this.tempMaxC,
    this.tempMinC,
  });

  final String city;
  final double tempC;
  final double? tempMaxC;
  final double? tempMinC;

  /// WMO 4677 weather code, as sent by Open-Meteo's `weather_code`.
  final int code;
  final bool isDay;
  final DateTime fetchedAt;

  String get condition => conditionText(code);
}

/// WMO weather code → the Chinese label shown next to the temperature.
String conditionText(int code) => switch (code) {
      0 => '晴',
      1 => '晴间多云',
      2 => '多云',
      3 => '阴',
      45 || 48 => '雾',
      51 || 53 || 55 => '毛毛雨',
      56 || 57 || 66 || 67 => '冻雨',
      61 => '小雨',
      63 => '中雨',
      65 => '大雨',
      71 => '小雪',
      73 => '中雪',
      75 => '大雪',
      77 => '雪粒',
      80 => '阵雨',
      81 => '强阵雨',
      82 => '暴雨',
      85 || 86 => '阵雪',
      95 => '雷阵雨',
      96 || 99 => '雷暴伴冰雹',
      _ => '未知',
    };

/// Keyless weather lookup: locate roughly by IP, then read the current
/// conditions from Open-Meteo. Every source is tried in turn, so one blocked
/// or failing endpoint does not take the whole reading down.
class WeatherClient {
  WeatherClient({HttpClient? http}) : _http = http ?? HttpClient();

  final HttpClient _http;

  static const _userAgent = 'XGameDesktop/1.0 (Windows)';
  static const _perRequestTimeout = Duration(seconds: 5);

  /// Free, keyless IP geolocation services, tried in order. ip-api.com leads
  /// despite its plain-HTTP free tier because it is the one that answers this
  /// machine reliably: ipwho.is rate-limits keyless callers and ipapi.co
  /// serves non-browser clients a Cloudflare challenge.
  static const locationApis = [
    'http://ip-api.com/json/',
    'https://ipwho.is/',
    'https://ipapi.co/json/',
  ];

  Future<WeatherInfo> fetch() async {
    var city = '';
    double? lat;
    double? lon;
    for (final endpoint in locationApis) {
      final json = await _getJson(endpoint);
      final place = json == null ? null : parseLocation(json);
      if (place == null) continue;
      lat = place.lat;
      lon = place.lon;
      city = place.city;
      break;
    }
    if (lat == null || lon == null) {
      throw const WeatherException('无法定位所在城市');
    }

    final url = 'https://api.open-meteo.com/v1/forecast'
        '?latitude=${lat.toStringAsFixed(4)}'
        '&longitude=${lon.toStringAsFixed(4)}'
        '&current=temperature_2m,is_day,weather_code'
        '&daily=temperature_2m_max,temperature_2m_min'
        '&timezone=auto&forecast_days=1';
    final json = await _getJson(url);
    final info = json == null ? null : parseWeather(json, city);
    if (info == null) throw const WeatherException('天气服务暂不可用');
    return info;
  }

  /// The three services spell the coordinates differently; failure payloads
  /// are rejected rather than read as (0, 0) in the Gulf of Guinea.
  static ({double lat, double lon, String city})? parseLocation(
      Map<String, dynamic> json) {
    if (json['success'] == false ||
        json['status'] == 'fail' ||
        json['error'] == true) {
      return null;
    }
    final lat = json['latitude'] ?? json['lat'];
    final lon = json['longitude'] ?? json['lon'];
    if (lat is! num || lon is! num) return null;
    return (
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      city: (json['city'] ?? '').toString().trim(),
    );
  }

  static WeatherInfo? parseWeather(Map<String, dynamic> json, String city) {
    final current = json['current'];
    if (current is! Map) return null;
    final temp = current['temperature_2m'];
    final code = current['weather_code'];
    if (temp is! num || code is! num) return null;

    final daily = json['daily'];
    double? firstOf(String key) {
      if (daily is! Map) return null;
      final values = daily[key];
      if (values is! List || values.isEmpty) return null;
      final value = values.first;
      return value is num ? value.toDouble() : null;
    }

    return WeatherInfo(
      city: city,
      tempC: temp.toDouble(),
      tempMaxC: firstOf('temperature_2m_max'),
      tempMinC: firstOf('temperature_2m_min'),
      code: code.toInt(),
      isDay: (current['is_day'] as num?)?.toInt() != 0,
      fetchedAt: DateTime.now(),
    );
  }

  Future<Map<String, dynamic>?> _getJson(String url) async {
    try {
      final request =
          await _http.getUrl(Uri.parse(url)).timeout(_perRequestTimeout);
      request.headers
        ..set(HttpHeaders.userAgentHeader, _userAgent)
        ..set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_perRequestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_perRequestTimeout);
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

class WeatherException implements Exception {
  const WeatherException(this.message);

  final String message;

  @override
  String toString() => message;
}
