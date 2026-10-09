import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/weather.dart';
import 'app_activity.dart';

enum WeatherStatus { loading, ready, failed }

/// Drives the panel header: the clock ticks every second, the weather reading
/// is fetched on start, refreshed on a slow cadence, and retried by itself
/// after a failure.
class WeatherProvider extends ChangeNotifier {
  /// [fetch] and [tick] exist so tests can supply a canned reading and skip
  /// the wall-clock timer.
  WeatherProvider({Future<WeatherInfo> Function()? fetch, Duration? tick})
      : _fetch = fetch ?? WeatherClient().fetch,
        _tick = tick ?? const Duration(seconds: 1);

  final Future<WeatherInfo> Function() _fetch;
  final Duration _tick;

  static const _refreshEvery = Duration(minutes: 30);
  static const _retryEvery = Duration(minutes: 3);

  Timer? _timer;
  bool _fetching = false;
  bool _disposed = false;
  DateTime _lastAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime now = DateTime.now();
  WeatherStatus status = WeatherStatus.loading;
  WeatherInfo? weather;

  /// The last fetch error. A reading already on screen stays visible when a
  /// later refresh fails — it is marked stale instead of blanked out.
  String error = '';

  void start() {
    if (_started) return;
    _started = true;
    AppActivity.visible.removeListener(_onActivity);
    AppActivity.visible.addListener(_onActivity);
    if (!AppActivity.isVisible) return;
    _resume();
    refresh();
  }

  bool _started = false;

  /// The clock is the only reason this ticks every second, and a hidden window
  /// shows no clock: the timer stops with it and starts again on the way back,
  /// with one immediate tick so the time on screen is right, and with the usual
  /// cadence check so a reading that went stale while hidden is refetched.
  void _onActivity() {
    if (AppActivity.isVisible) {
      _resume();
      _onTick();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _resume() {
    if (_disposed) return;
    _timer ??= Timer.periodic(_tick, (_) => _onTick());
  }

  void _onTick() {
    now = DateTime.now();
    _notify();
    if (_fetching) return;
    // Started while hidden, so nothing was ever fetched; the first visible
    // moment is the retry.
    if (status == WeatherStatus.loading && weather == null) {
      refresh();
      return;
    }
    final age = now.difference(
        status == WeatherStatus.ready ? weather!.fetchedAt : _lastAttempt);
    if (status == WeatherStatus.ready && age >= _refreshEvery) refresh();
    if (status == WeatherStatus.failed && age >= _retryEvery) refresh();
  }

  Future<void> refresh() async {
    if (_fetching) return;
    _fetching = true;
    _lastAttempt = DateTime.now();
    if (weather == null) status = WeatherStatus.loading;
    _notify();
    try {
      weather = await _fetch();
      status = WeatherStatus.ready;
      error = '';
    } on WeatherException catch (e) {
      error = e.message;
      if (weather == null) status = WeatherStatus.failed;
    } catch (_) {
      error = '天气服务暂不可用';
      if (weather == null) status = WeatherStatus.failed;
    } finally {
      _fetching = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    AppActivity.visible.removeListener(_onActivity);
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
