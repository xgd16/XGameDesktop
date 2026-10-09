import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../core/typography.dart';
import '../native/hwprobe_service.dart';
import '../native/volumes.dart';
import 'clock_weather.dart';
import 'nav.dart';
import 'widgets.dart';

/// The telemetry panel — the app's signature element. One calm surface,
/// hairline section dividers, and a single hero readout for the CPU.
///
/// It is read-only, but not out of reach: the pad has to be able to get here
/// and scroll, so the panel lights its edge while the focus is on it.
class MetricsPanel extends StatefulWidget {
  const MetricsPanel({super.key});

  @override
  State<MetricsPanel> createState() => _MetricsPanelState();
}

class _MetricsPanelState extends State<MetricsPanel> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // Status only: this build holds the whole column, and the service notifies
    // once a second with new readings. The sections below watch for those.
    final status = context.select<HwprobeService, HwprobeStatus>(
      (service) => service.status,
    );

    // The panel refreshes once a second, and Windows accessibility tools that
    // activate semantics make every refresh rebuild the UIA tree — which trips
    // an engine bug (accessibility_bridge.cc "Nodes left pending"). A HUD has
    // no screen-reader use, so it stays out of the semantics tree entirely.
    return ExcludeSemantics(
      child: Container(
        width: 384,
        decoration: BoxDecoration(
          // The pad can land here, so the panel has to say so plainly: the
          // hairline lights up and the column takes a faint wash of the accent.
          // The wash is what separates "the highlight is on this panel" from a
          // hover on the edge nobody notices while looking at the tiles.
          color: _focused ? c.accent.withValues(alpha: 0.05) : null,
          border: Border(
            left: BorderSide(
              color: _focused ? c.accent : c.border,
              width: _focused ? 2 : 1,
            ),
          ),
        ),
        // The clock/weather header is pinned above the status switcher: the time
        // stays put while the telemetry below loads, fails, or scrolls.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ClockWeatherPanel(),
            Container(height: 1, color: c.border),
            Expanded(
              child: AnimatedSwitcher(
                duration: Motion.base,
                child: switch (status) {
                  HwprobeStatus.loading => _Loading(
                    c: c,
                    key: const ValueKey('loading'),
                  ),
                  HwprobeStatus.backendMissing || HwprobeStatus.initFailed =>
                    _MissingBackend(c: c, key: const ValueKey('missing')),
                  HwprobeStatus.ready => _ReadyPanel(
                    key: const ValueKey('ready'),
                    onFocusChange: (focused) =>
                        setState(() => _focused = focused),
                  ),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.c, super.key});

  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.2, color: c.accent),
      ),
    );
  }
}

class _MissingBackend extends StatelessWidget {
  const _MissingBackend({required this.c, super.key});

  final AppColors c;

  @override
  Widget build(BuildContext context) {
    final service = context.read<HwprobeService>();
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.monitor_heart_outlined, size: 30, color: c.textMuted),
          const SizedBox(height: 14),
          Text(
            '监控后端未加载',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            service.initError,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 18),
          _PanelButton(label: '重试', color: c.accent, onTap: service.start),
        ],
      ),
    );
  }
}

/// The panel's own text button: the app's accent ring while the pad or the
/// keyboard is on it, and none of [TextButton]'s Material overlay — that
/// overlay was the one highlight left in the app that a ring-less control
/// could hide in.
class _PanelButton extends StatelessWidget {
  const _PanelButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tappable(
      onTap: onTap,
      builder: (context, state) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: state.focused ? c.accent : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _ReadyPanel extends StatelessWidget {
  const _ReadyPanel({super.key, required this.onFocusChange});

  final ValueChanged<bool> onFocusChange;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // Only these facts decide which sections exist; the readings inside
    // them are their own widgets' business, and this build rebuilds the whole
    // column — so it must not follow every 1 Hz reading.
    final (hasBattery, hasFans, driverMissing) = context
        .select<HwprobeService, (bool, bool, bool)>(
          (service) =>
              (service.hasBattery, service.hasFanRows, service.driverMissing),
        );

    final sections = <Widget>[
      const _CpuSection(),
      const _GpuSection(),
      // Like the battery section, the fan section only exists when the machine
      // has something to show — most boards expose no tachometer without the
      // kernel driver, and some expose none at all.
      if (hasFans) const _FanSection(),
      const _MemorySection(),
      // Desktops have no battery device — the section only exists on
      // handhelds/laptops, so it disappears with the machine.
      if (hasBattery) const _BatterySection(),
      const _NetworkSection(),
      const _StorageSection(),
      if (driverMissing) const _DriverNotice(),
    ];

    // Each section gets a boundary of its own: the readings arrive together but
    // they do not move together, and a section whose numbers did not change
    // then skips the raster instead of being repainted because the one above it
    // was. It also gives the entrance wave something to move as a layer rather
    // than a fresh rasterization per frame.
    final children = <Widget>[
      Entrance(child: RepaintBoundary(child: sections.first)),
    ];
    for (var i = 1; i < sections.length; i++) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Divider(height: 1, color: c.border),
        ),
      );
      children.add(
        Entrance(
          delay: Duration(milliseconds: 55 * i),
          offset: const Offset(14, 0),
          child: RepaintBoundary(child: sections[i]),
        ),
      );
    }

    return _PanelScrollArea(
      onFocusChange: onFocusChange,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// The telemetry column as one focus stop: up/down walk its content, left and
/// right hand the focus back to the rest of the page, and LT/RT page it (the
/// shell's ScrollIntent finds the scroll view through this node's context —
/// which is why the node lives *inside* it).
class _PanelScrollArea extends StatefulWidget {
  const _PanelScrollArea({required this.onFocusChange, required this.child});

  final ValueChanged<bool> onFocusChange;
  final Widget child;

  @override
  State<_PanelScrollArea> createState() => _PanelScrollAreaState();
}

class _PanelScrollAreaState extends State<_PanelScrollArea> {
  final _controller = ScrollController();
  final _focusNode = FocusNode(debugLabel: 'telemetry');

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() => widget.onFocusChange(_focusNode.hasFocus));
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _scrollBy(double delta) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: Motion.fast,
      curve: Motion.outCubic,
    );
  }

  /// The pad asks here before it walks the focus away.
  Object? _onDirection(FocusDirectionIntent intent) {
    switch (intent.direction) {
      case TraversalDirection.up:
        _scrollBy(-120);
        return true;
      case TraversalDirection.down:
        _scrollBy(120);
        return true;
      case TraversalDirection.left:
      case TraversalDirection.right:
        return Actions.maybeInvoke(
          context,
          DirectionalFocusIntent(intent.direction),
        );
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    // Left and right are not handled here: they bubble on to the app's
    // traversal shortcuts and take the focus back to the grid.
    if (key == LogicalKeyboardKey.arrowUp) {
      _scrollBy(-120);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _scrollBy(120);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const _PanelScrollBehavior(),
      child: SingleChildScrollView(
        controller: _controller,
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
        child: Actions(
          // An intent is looked up from the focused node's context upwards, so
          // this has to enclose the Focus, not sit inside it.
          actions: {
            FocusDirectionIntent: CallbackAction<FocusDirectionIntent>(
              onInvoke: _onDirection,
            ),
          },
          child: Focus(
            focusNode: _focusNode,
            onKeyEvent: _onKey,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _PanelScrollBehavior extends ScrollBehavior {
  const _PanelScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final c = AppColors.of(context);
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(c.borderStrong),
        thickness: const WidgetStatePropertyAll(3),
        radius: const Radius.circular(3),
      ),
      child: Scrollbar(
        controller: details.controller,
        thumbVisibility: false,
        child: child,
      ),
    );
  }
}

// ---- shared pieces ----

Color usageColor(double pct, AppColors c) => pct >= 95
    ? c.danger
    : pct >= 80
    ? c.warn
    : c.accent;

Color tempColor(double t, AppColors c) => t >= 85
    ? c.danger
    : t >= 70
    ? c.warn
    : c.textPrimary;

/// Battery charge: unlike usage meters, a *low* value is the bad one.
Color batteryColor(double pct, AppColors c) => pct <= 15
    ? c.danger
    : pct <= 30
    ? c.warn
    : c.accent;

String formatKbps(double? kbps) {
  if (kbps == null) return '--';
  if (kbps >= 1024) return '${(kbps / 1024).toStringAsFixed(1)} MB/s';
  return '${kbps.toStringAsFixed(0)} KB/s';
}

String formatMhz(double? mhz) {
  if (mhz == null) return '--';
  if (mhz >= 1000) return '${(mhz / 1000).toStringAsFixed(2)} GHz';
  return '${mhz.toStringAsFixed(0)} MHz';
}

/// A fan at 0 is stopped, not missing; a reading that never came is '--'.
String fanValueText(double? rpm) => rpm == null
    ? '--'
    : rpm <= 0
    ? '停转'
    : '${rpm.toStringAsFixed(0)} RPM';

/// Watts: one decimal below 10 W (memory power sits around 1–5 W), integer above.
String formatWatt(double? w) {
  if (w == null) return '--';
  return w < 10 ? '${w.toStringAsFixed(1)}W' : '${w.toStringAsFixed(0)}W';
}

String formatMb(double? mb) {
  if (mb == null) return '--';
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '${mb.toStringAsFixed(0)} MB';
}

String formatBytes(int bytes) {
  final gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1024) return '${(gb / 1024).toStringAsFixed(2)} TB';
  if (gb >= 100) return '${gb.toStringAsFixed(0)} GB';
  return '${gb.toStringAsFixed(1)} GB';
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.icon, this.label, {this.detail, required this.c});

  final IconData icon;
  final String label;
  final String? detail;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 15, color: c.accent),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: c.textMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---- CPU (hero) ----

class _CpuSection extends StatelessWidget {
  const _CpuSection();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final service = context.watch<HwprobeService>();
    final usage = service.cpuUsage;
    final temp = service.cpuTemp;
    final freq = service.cpuFreqMhz;
    final power = service.cpuPowerW;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(Icons.memory, '处理器', detail: service.cpuName, c: c),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // A usage reading wobbles by more than the default threshold (3)
            // between two 1 Hz samples, so easing every wobble kept the window
            // rendering — and the frosted glass elsewhere with it — for most
            // of every second. Eight points, the bar below's own threshold, is
            // when a load change is worth animating.
            FlipValue(
              usage,
              snapAt: 8,
              style: TelemetryText.hero(
                usage != null ? usageColor(usage, c) : c.textMuted,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 7),
              child: Text('%', style: TelemetryText.number(20, c.textMuted)),
            ),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _miniStat(context, '频率', freq != null ? formatMhz(freq) : null),
                const SizedBox(height: 4),
                _miniStat(
                  context,
                  '温度',
                  temp != null ? '${temp.toStringAsFixed(0)}°C' : null,
                  valueColor: temp != null ? tempColor(temp, c) : null,
                ),
                const SizedBox(height: 4),
                _miniStat(context, '功耗', power != null ? formatWatt(power) : null),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        MeterBar(
          value: usage,
          color: usage != null ? usageColor(usage, c) : c.accent,
        ),
      ],
    );
  }
}

/// One label + value pair in a section's corner. A null value is a reading
/// this machine cannot produce — no such sensor, or the driver/admin gate —
/// and the whole item stands down rather than sit there as a permanent '--'.
Widget _miniStat(
  BuildContext context,
  String label,
  String? value, {
  Color? valueColor,
}) {
  if (value == null) return const SizedBox.shrink();
  final c = AppColors.of(context);
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: TextStyle(fontSize: 11, color: c.textMuted)),
      const SizedBox(width: 6),
      Text(
        value,
        style: TelemetryText.number(13.5, valueColor ?? c.textSecondary),
      ),
    ],
  );
}

// ---- GPU ----

class _GpuSection extends StatelessWidget {
  const _GpuSection();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final service = context.watch<HwprobeService>();
    final usage = service.gpuUsage;
    final temp = service.gpuTemp;
    final power = service.gpuPowerW;
    final memUsed = service.gpuMemUsedMb;
    final memTotal = service.gpuMemTotalMb;
    final memPct = memUsed != null && memTotal != null && memTotal > 0
        ? memUsed / memTotal * 100
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          Icons.videogame_asset,
          '显卡',
          detail: service.gpuName,
          c: c,
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Eight points, like the CPU hero: a usage reading wobbles more
            // than the default threshold between two 1 Hz samples.
            FlipValue(
              usage,
              snapAt: 8,
              style: TelemetryText.number(
                26,
                usage != null ? c.textPrimary : c.textMuted,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 3),
              child: Text('%', style: TelemetryText.number(13, c.textMuted)),
            ),
            const Spacer(),
            _miniStat(
              context,
              '温度',
              temp != null ? '${temp.toStringAsFixed(0)}°C' : null,
              valueColor: temp != null ? tempColor(temp, c) : null,
            ),
            const SizedBox(width: 12),
            _miniStat(context, '功耗', power != null ? formatWatt(power) : null),
          ],
        ),
        const SizedBox(height: 10),
        MeterBar(
          value: usage,
          color: usage != null ? usageColor(usage, c) : c.accent,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text('显存', style: TextStyle(fontSize: 11, color: c.textMuted)),
            const SizedBox(width: 8),
            Expanded(
              child: MeterBar(value: memPct, color: c.accent, height: 4),
            ),
            const SizedBox(width: 8),
            Text(
              '${formatMb(memUsed)} / ${formatMb(memTotal)}',
              style: TelemetryText.number(12, c.textSecondary),
            ),
          ],
        ),
      ],
    );
  }
}

// ---- Fans ----

/// One quiet row per fan that has actually turned. No bar: a fan has no
/// natural maximum, so a percentage would invent one. Rows for the probe's
/// dead headers — never spun, never read — are dropped upstream (see
/// [HwprobeService.fanReadings]).
class _FanSection extends StatelessWidget {
  const _FanSection();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final service = context.watch<HwprobeService>();
    final fans = service.fanReadings;
    // Every row hanging off one device, none of them already carrying it as a
    // label suffix: say which one, the way the CPU and GPU sections lead with
    // theirs.
    final devices = {for (final fan in fans) fan.device};
    final detail =
        devices.length == 1 && fans.every((fan) => !fan.label.contains(' · '))
        ? devices.first
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(Icons.air, '风扇', detail: detail, c: c),
        for (final fan in fans)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    fan.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ),
                Text(
                  fanValueText(fan.rpm),
                  style: TelemetryText.number(
                    12.5,
                    fan.rpm == null || fan.rpm == 0
                        ? c.textMuted
                        : c.textPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---- Memory ----

class _MemorySection extends StatelessWidget {
  const _MemorySection();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final service = context.watch<HwprobeService>();
    final pct = service.memoryUsagePct;
    final used = service.memoryUsedMb;
    final total = service.memoryTotalMb;
    final power = service.memoryPowerW;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          Icons.dns,
          '内存',
          detail: service.memoryDesc.isNotEmpty ? service.memoryDesc : null,
          c: c,
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FlipValue(
              pct,
              style: TelemetryText.number(
                26,
                pct != null ? c.textPrimary : c.textMuted,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 3),
              child: Text('%', style: TelemetryText.number(13, c.textMuted)),
            ),
            const Spacer(),
            _miniStat(context, '功耗', power != null ? formatWatt(power) : null),
            const SizedBox(width: 14),
            Text(
              '${formatMb(used)} / ${formatMb(total)}',
              style: TelemetryText.number(13, c.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: 10),
        MeterBar(
          value: pct,
          color: pct != null ? usageColor(pct, c) : c.accent,
        ),
      ],
    );
  }
}

// ---- Battery ----

/// Charge as the hero number, state as the label. Only built when the machine
/// actually has a battery ([HwprobeService.hasBattery]).
class _BatterySection extends StatelessWidget {
  const _BatterySection();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final service = context.watch<HwprobeService>();
    final bat = service.battery;
    if (bat == null) return const SizedBox.shrink();

    final pct = service.batteryChargePct;
    final state = service.batteryStateText;
    final rate = service.batteryRateW;
    final charging = state != null && state.startsWith('充电中');
    final icon = charging
        ? Icons.battery_charging_full
        : pct != null && pct <= 15
        ? Icons.battery_alert
        : Icons.battery_5_bar;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(icon, '电池', detail: bat.name, c: c),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FlipValue(
              pct,
              style: TelemetryText.number(
                26,
                pct != null ? batteryColor(pct, c) : c.textMuted,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 3),
              child: Text('%', style: TelemetryText.number(13, c.textMuted)),
            ),
            const Spacer(),
            _miniStat(context, '状态', state),
            const SizedBox(width: 12),
            _miniStat(
              context,
              '功率',
              // Magnitude only: 充电中/放电中 in the 状态 item already says
              // which way the watts flow, and a lone +/- reads as clutter.
              rate != null ? formatWatt(rate.abs()) : null,
            ),
            if (bat.healthPct != null) ...[
              const SizedBox(width: 12),
              _miniStat(context, '健康', '${bat.healthPct!.toStringAsFixed(0)}%'),
            ],
          ],
        ),
        const SizedBox(height: 10),
        MeterBar(
          value: pct,
          color: pct != null ? batteryColor(pct, c) : c.accent,
        ),
      ],
    );
  }
}

// ---- Network ----

class _NetworkSection extends StatelessWidget {
  const _NetworkSection();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final service = context.watch<HwprobeService>();
    final down = service.downloadKbps;
    final up = service.uploadKbps;
    final net = service.activeNet;
    final history = service.history['down'] ?? const <double>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(Icons.lan, '网络', detail: net?.name, c: c),
        Row(
          children: [
            Icon(Icons.south_west, size: 13, color: c.ok),
            const SizedBox(width: 5),
            Text(
              formatKbps(down),
              style: TelemetryText.number(16, c.textPrimary),
            ),
            const SizedBox(width: 18),
            Icon(Icons.north_east, size: 13, color: c.accent),
            const SizedBox(width: 5),
            Text(
              formatKbps(up),
              style: TelemetryText.number(16, c.textSecondary),
            ),
            const Spacer(),
            if (history.length >= 2)
              SizedBox(
                width: 120,
                child: Sparkline(values: history.toList(), color: c.accent),
              ),
          ],
        ),
      ],
    );
  }
}

// ---- Storage ----

class _StorageSection extends StatelessWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final service = context.watch<HwprobeService>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(Icons.storage, '存储', c: c),
        if (service.volumes.isEmpty)
          Text(
            '没有检测到本地磁盘分区',
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
        for (final volume in service.volumes)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _VolumeRow(volume: volume),
          ),
        if (service.disks.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text('磁盘活动', style: TextStyle(fontSize: 11, color: c.textMuted)),
          const SizedBox(height: 8),
          for (var i = 0; i < service.disks.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _DiskActivityLine(index: i),
            ),
        ],
      ],
    );
  }
}

/// Volume usage: the bar is the occupied percentage, with used/total text.
class _VolumeRow extends StatelessWidget {
  const _VolumeRow({required this.volume});

  final VolumeInfo volume;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final pct = volume.usedPct;
    final name = volume.label.isEmpty
        ? volume.letter
        : '${volume.letter} ${_shorten(volume.label, 12)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(name, style: TextStyle(fontSize: 12, color: c.textSecondary)),
            const Spacer(),
            Text(
              '${formatBytes(volume.usedBytes)} / ${formatBytes(volume.totalBytes)}',
              style: TelemetryText.number(11.5, c.textMuted),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 34,
              child: Text(
                '${pct.toStringAsFixed(0)}%',
                textAlign: TextAlign.right,
                style: TelemetryText.number(12, usageColor(pct, c)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        MeterBar(value: pct, color: usageColor(pct, c), height: 4),
      ],
    );
  }

  static String _shorten(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}…' : s;
}

/// Physical disk telemetry on one quiet line: model, activity, rates, temp.
class _DiskActivityLine extends StatelessWidget {
  const _DiskActivityLine({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final service = context.watch<HwprobeService>();
    final disk = service.disks[index];
    final activity = service.diskActivity(index);
    final read = service.diskReadKbps(index);
    final write = service.diskWriteKbps(index);
    final temp = service.diskTemp(index);

    final parts = <String>[
      if (activity != null) '活动 ${activity.toStringAsFixed(0)}%',
      '读 ${formatKbps(read)}',
      '写 ${formatKbps(write)}',
      if (temp != null) '${temp.toStringAsFixed(0)}°C',
    ];

    return Row(
      children: [
        Expanded(
          child: Text(
            _shortenModel(disk.model),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: c.textMuted),
          ),
        ),
        const SizedBox(width: 10),
        Text(parts.join('  '), style: TelemetryText.number(11, c.textMuted)),
      ],
    );
  }

  static String _shortenModel(String model) {
    final cleaned = model.replaceAll(_whitespace, ' ').trim();
    return cleaned.length > 26 ? '${cleaned.substring(0, 26)}…' : cleaned;
  }

  /// Compiled once: a model name does not change between rebuilds, and this
  /// line rebuilds on every telemetry tick.
  static final _whitespace = RegExp(r'\s+');
}

// ---- driver notice ----

class _DriverNotice extends StatelessWidget {
  const _DriverNotice();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // Driver service already installed (either now or earlier) — the only
    // missing piece for temps is an elevated process. A bool, so a rebuilt
    // notice only happens when it changes (the getter behind it is memoized).
    final needsElevate = context.select<HwprobeService, bool>(
      (service) =>
          service.driverInstallPendingRestart || service.driverServiceRunning,
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(
            needsElevate ? Icons.restart_alt : Icons.device_thermostat,
            size: 17,
            color: needsElevate ? c.ok : c.warn,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              needsElevate ? '温度与功耗读数需要以管理员身份运行' : '温度、功耗与风扇读数需要硬件驱动',
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ),
          _PanelButton(
            label: needsElevate ? '管理员重启' : '安装驱动',
            color: needsElevate ? c.ok : c.accent,
            onTap: needsElevate
                ? () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final service = context.read<HwprobeService>();
                    final ok = await service.restartAsAdmin();
                    if (!ok) {
                      messenger.showSnackBar(
                        SnackBar(
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: c.surfaceHover,
                          content: Text(
                            '未能启动管理员实例,可在开始菜单右键应用选择"以管理员身份运行"',
                            style: TextStyle(color: c.textPrimary),
                          ),
                        ),
                      );
                    }
                  }
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final rc = await context
                        .read<HwprobeService>()
                        .installDriver();
                    if (rc != 0) {
                      messenger.showSnackBar(
                        SnackBar(
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: c.surfaceHover,
                          content: Text(
                            '驱动安装程序未能启动 (代码 $rc),请稍后重试',
                            style: TextStyle(color: c.textPrimary),
                          ),
                        ),
                      );
                    }
                  },
          ),
        ],
      ),
    );
  }
}
