import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/clock_text.dart';
import '../core/theme.dart';
import '../core/typography.dart';
import '../net/weather.dart';
import '../state/weather_provider.dart';
import 'widgets.dart';

/// Fixed header of the telemetry panel: a hero clock on the left, the current
/// conditions on the right. Kept outside the panel's status switcher, so the
/// time is on screen whatever the hardware probe is doing.
class ClockWeatherPanel extends StatelessWidget {
  const ClockWeatherPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final weather = context.read<WeatherProvider>();
    return Entrance(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
        child: Row(
          children: [
            // Only the clock follows the provider's 1 Hz tick. The conditions
            // block has nothing time-dependent in it; rebuilding it 86 400
            // times a day is not free.
            Selector<WeatherProvider, DateTime>(
              selector: (_, weather) => weather.now,
              builder: (context, now, _) => _Clock(now: now, c: c),
            ),
            const Spacer(),
            const SizedBox(width: 12),
            // Rebuilt when the reading changes, not when the second does.
            Selector<WeatherProvider, (WeatherInfo?, WeatherStatus, String)>(
              selector: (_, weather) =>
                  (weather.weather, weather.status, weather.error),
              builder: (context, data, _) => _Conditions(
                info: data.$1,
                status: data.$2,
                error: data.$3,
                onRefresh: weather.refresh,
                c: c,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Clock extends StatelessWidget {
  const _Clock({required this.now, required this.c});

  final DateTime now;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(clockHm(now), style: TelemetryText.number(34, c.textPrimary)),
            const SizedBox(width: 4),
            Text(clockSeconds(now), style: TelemetryText.number(14, c.textMuted)),
          ],
        ),
        const SizedBox(height: 4),
        Text(dateCn(now), style: TextStyle(fontSize: 11.5, color: c.textMuted)),
      ],
    );
  }
}

/// The conditions block doubles as the refresh button.
class _Conditions extends StatelessWidget {
  const _Conditions({
    required this.info,
    required this.status,
    required this.error,
    required this.onRefresh,
    required this.c,
  });

  final WeatherInfo? info;
  final WeatherStatus status;
  final String error;
  final Future<void> Function() onRefresh;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    final stale = info != null && error.isNotEmpty;
    return Tooltip(
      message: _tooltip(info, stale),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onRefresh,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 176),
            child: info == null ? _placeholder() : _reading(info!, stale),
          ),
        ),
      ),
    );
  }

  String _tooltip(WeatherInfo? info, bool stale) {
    if (info == null) {
      return status == WeatherStatus.loading ? '正在获取天气…' : '$error · 点击重试';
    }
    if (stale) return '$error · 点击重试';
    final parts = [
      info.condition,
      if (info.city.isNotEmpty) info.city,
      if (info.tempMaxC != null && info.tempMinC != null)
        '最高 ${info.tempMaxC!.round()}° 最低 ${info.tempMinC!.round()}°',
    ];
    return '${parts.join(' · ')} · 点击刷新';
  }

  Widget _placeholder() {
    if (status == WeatherStatus.loading) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.8, color: c.accent),
          ),
          const SizedBox(width: 8),
          Text('获取天气…', style: TextStyle(fontSize: 12, color: c.textMuted)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 17, color: c.textMuted),
            const SizedBox(width: 6),
            Text('天气不可用', style: TextStyle(fontSize: 12, color: c.textMuted)),
          ],
        ),
        const SizedBox(height: 3),
        Text('点击重试', style: TextStyle(fontSize: 11, color: c.accent)),
      ],
    );
  }

  Widget _reading(WeatherInfo info, bool stale) {
    final max = info.tempMaxC?.round();
    final min = info.tempMinC?.round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              weatherIconFor(info.code, info.isDay),
              size: 22,
              color: stale ? c.warn : c.accent,
            ),
            const SizedBox(width: 7),
            Text('${info.tempC.round()}°',
                style: TelemetryText.number(26, c.textPrimary)),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          info.city.isEmpty ? info.condition : '${info.condition} · ${info.city}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11.5, color: stale ? c.warn : c.textSecondary),
        ),
        if (max != null && min != null) ...[
          const SizedBox(height: 1),
          Text('↑$max°  ↓$min°', style: TelemetryText.number(11, c.textMuted)),
        ],
      ],
    );
  }
}

/// WMO weather code → the closest Material glyph. [isDay] only changes the
/// clear-sky icon (sun vs moon).
IconData weatherIconFor(int code, bool isDay) => switch (code) {
      0 || 1 => isDay ? Icons.wb_sunny_outlined : Icons.nightlight_outlined,
      2 => Icons.cloud_queue,
      3 => Icons.cloud,
      45 || 48 => Icons.foggy,
      51 || 53 || 55 || 56 || 57 => Icons.grain,
      61 || 63 || 65 || 66 || 67 => Icons.water_drop_outlined,
      71 || 73 || 75 || 77 || 85 || 86 => Icons.ac_unit,
      80 || 81 || 82 => Icons.umbrella_outlined,
      95 || 96 || 99 => Icons.thunderstorm_outlined,
      _ => Icons.cloud_outlined,
    };
