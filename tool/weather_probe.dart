// Dev-only probe: exercises the production weather chain over the real
// network and prints the parsed reading (or the failure the panel would show).
// Run: dart run tool/weather_probe.dart
// ignore_for_file: avoid_print
import 'package:xgame_desktop/net/weather.dart';

/// Real-network probe for the keyless weather chain, run from the Dart VM:
/// `dart run tool/weather_probe.dart`. Prints the parsed reading, or the
/// failure the panel would show.
Future<void> main() async {
  final watch = Stopwatch()..start();
  try {
    final info = await WeatherClient().fetch();
    print('OK ${watch.elapsedMilliseconds}ms  ${info.city} · ${info.condition} '
        '${info.tempC.round()}°C  最高 ${info.tempMaxC?.round()}° 最低 ${info.tempMinC?.round()}°  '
        'isDay=${info.isDay} code=${info.code}');
  } catch (e) {
    print('FAILED ${watch.elapsedMilliseconds}ms  $e');
  }
}
