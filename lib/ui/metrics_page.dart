import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/typography.dart';
import '../data/metric_store.dart';
import '../state/metrics_provider.dart';
import 'metric_chart.dart';
import 'widgets.dart';

/// How much of the history the charts show, and how many points they are drawn
/// from.
///
/// A window is bucketed to roughly one point per two pixels of a card's plot:
/// enough that a spike keeps its shape, few enough that the painter never walks
/// a hundred thousand of them. The bucket is therefore a time, not a count of
/// samples — the same curve comes out whether the readings were collected every
/// second or every thirty.
enum MetricRange {
  hour('1 小时', Duration(hours: 1), 120),
  sixHours('6 小时', Duration(hours: 6), 144),
  day('24 小时', Duration(days: 1), 192),
  week('7 天', Duration(days: 7), 336);

  const MetricRange(this.label, this.span, this.buckets);

  final String label;
  final Duration span;
  final int buckets;

  /// How often the curves are recomputed while this window is up. The newest
  /// bucket of the seven-day view is half an hour wide, so redrawing it every
  /// collection would be a scan nobody can see the result of.
  Duration get refreshEvery => switch (this) {
        MetricRange.hour => const Duration(seconds: 3),
        MetricRange.sixHours => const Duration(seconds: 10),
        MetricRange.day => const Duration(seconds: 30),
        MetricRange.week => const Duration(minutes: 1),
      };
}

/// One card of the page: what it is about, the readings it draws, and the
/// brush each of them takes. Two readings per card is the point — CPU beside
/// GPU, down beside up — because the comparison is why somebody opens this
/// page; a card never mixes units, since one axis cannot carry two.
class _ChartCardSpec {
  const _ChartCardSpec(this.title, this.icon, this.fields);

  final String title;
  final IconData icon;
  final List<MetricField> fields;
}

const _cards = <_ChartCardSpec>[
  _ChartCardSpec(
      '占用率', Icons.speed, [MetricField.cpuPct, MetricField.gpuPct]),
  _ChartCardSpec('温度', Icons.thermostat,
      [MetricField.cpuTemp, MetricField.gpuTemp]),
  _ChartCardSpec(
      '功耗', Icons.bolt, [MetricField.cpuPowerW, MetricField.gpuPowerW]),
  _ChartCardSpec('内存占用率', Icons.memory, [MetricField.memPct]),
  _ChartCardSpec('内存用量', Icons.memory, [MetricField.memUsedMb]),
  _ChartCardSpec('显存用量', Icons.sd_storage, [MetricField.gpuMemMb]),
  _ChartCardSpec('CPU 频率', Icons.timeline, [MetricField.cpuFreqMhz]),
  _ChartCardSpec('网络速率', Icons.network_check,
      [MetricField.netDownKbps, MetricField.netUpKbps]),
  _ChartCardSpec('磁盘活动', Icons.storage, [MetricField.diskPct]),
  _ChartCardSpec('磁盘吞吐', Icons.sd_storage,
      [MetricField.diskReadKbps, MetricField.diskWriteKbps]),
  _ChartCardSpec('风扇转速', Icons.toys, [MetricField.fanRpm]),
];

/// Every field the page draws, in one list: the read behind it takes them all
/// in one query — SQLite scans the window once and averages each column per
/// bucket, so a page of eleven cards costs one scan, not eleven.
final List<MetricField> _drawnFields = () {
  final seen = <MetricField>{};
  for (final card in _cards) {
    seen.addAll(card.fields);
  }
  return seen.toList();
}();

/// The device monitoring page: what the machine has been doing, drawn from the
/// history the recorder writes every few seconds.
///
/// Built like the statistics page — a full-bleed surface over the shell, a
/// header with its actions and a close button, and its own focus scope — with
/// one difference that matters: it listens to the recorder, so the figures
/// follow the machine while the page is open.
class MetricsPage extends StatefulWidget {
  const MetricsPage({super.key, required this.onClose, this.focusNode});

  final VoidCallback onClose;

  /// The page's own focus scope, supplied by the shell so it can hand the pad's
  /// highlight to the page the moment it opens.
  final FocusNode? focusNode;

  @override
  State<MetricsPage> createState() => _MetricsPageState();
}

class _MetricsPageState extends State<MetricsPage> {
  MetricRange _range = MetricRange.hour;

  /// 清空记录 has been pressed once. The second press is the one that drops the
  /// history — the app draws its own chrome everywhere and has no dialog, so
  /// the confirmation is a bar inside the page, the way 清空统计 does it.
  bool _confirmingClear = false;

  /// The drawn window, and when it was read. Rebuilt from the database rather
  /// than accumulated in memory: the history outlives the page and the app.
  List<MetricPoint> _points = const [];
  DateTime? _drawnAt;

  MetricsProvider? _metrics;

  @override
  void initState() {
    super.initState();
    _metrics = context.read<MetricsProvider>();
    _reload();
    _metrics!.addListener(_onSample);
  }

  @override
  void dispose() {
    _metrics?.removeListener(_onSample);
    super.dispose();
  }

  /// Reads the window back out of the history.
  void _reload() {
    final metrics = _metrics;
    if (metrics == null) return;
    final now = metrics.now;
    _points = metrics.series(
      fields: _drawnFields,
      from: now.subtract(_range.span),
      to: now,
      buckets: _range.buckets,
    );
    _drawnAt = now;
  }

  /// A reading landed. The figures follow it every time; the curves only when
  /// this window's own clock says so — see [MetricRange.refreshEvery].
  void _onSample() {
    if (!mounted) return;
    final metrics = _metrics;
    final drawnAt = _drawnAt;
    final stale = metrics == null ||
        drawnAt == null ||
        metrics.now.difference(drawnAt) >= _range.refreshEvery;
    setState(() {
      if (stale) _reload();
    });
  }

  void _selectRange(MetricRange range) {
    if (range == _range) return;
    setState(() {
      _range = range;
      _reload();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      // Esc backs out of the confirmation first; the page closes on the next
      // one. A pad's B does the same through the DismissIntent below.
      if (_confirmingClear) {
        setState(() => _confirmingClear = false);
      } else {
        widget.onClose();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final metrics = context.watch<MetricsProvider>();
    final count = metrics.sampleCount;

    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            if (_confirmingClear) {
              setState(() => _confirmingClear = false);
            } else {
              widget.onClose();
            }
            return true;
          },
        ),
      },
      child: FocusTraversalGroup(
        child: Focus(
          focusNode: widget.focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Material(
            color: c.bg,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 20, 30, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(c, metrics, count),
                  const SizedBox(height: 16),
                  if (_confirmingClear) _confirmBar(c, metrics),
                  Container(height: 1, color: c.border),
                  Expanded(
                    child: count == 0 ? _empty(c, metrics) : _grid(c),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppColors c, MetricsProvider metrics, int count) {
    return Row(
      children: [
        Text(
          '设备监控',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(width: 12),
        // Flexible so the window's own summary — which runs to a couple of
        // dates when the history is a week old — gives way before the range
        // switch does.
        Flexible(
          child: Text(
            _summary(metrics),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: c.textMuted),
          ),
        ),
        const SizedBox(width: 14),
        Segmented<MetricRange>(
          value: _range,
          options: [
            for (final range in MetricRange.values) (range, range.label),
          ],
          onChanged: _selectRange,
        ),
        const SizedBox(width: 14),
        GhostButton(
          label: '清空记录',
          icon: Icons.delete_outline_rounded,
          tone: GhostButtonTone.danger,
          // Nothing recorded: the button stays where it is, inert rather than
          // hidden, so the header does not reflow.
          onTap:
              count == 0 ? null : () => setState(() => _confirmingClear = true),
        ),
        const SizedBox(width: 14),
        PageCloseButton(
          key: const Key('metricsClose'),
          tooltip: '关闭监控 (Esc)',
          onTap: widget.onClose,
        ),
      ],
    );
  }

  /// What the history holds, in one line: how many readings, how far back they
  /// reach, and how much of them is kept.
  String _summary(MetricsProvider metrics) {
    final count = metrics.sampleCount;
    if (count == 0) return '还没有记录';
    final first = metrics.firstSample;
    final last = metrics.lastSample;
    final covered = first == null || last == null || last.isBefore(first)
        ? ''
        : ' · 覆盖 ${_duration(last.difference(first))}';
    return '共 $count 条$covered · 只留近 7 天';
  }

  /// The second press 清空记录 asks for, and the way out of it.
  Widget _confirmBar(AppColors c, MetricsProvider metrics) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: c.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '清空后无法恢复：最近 7 天采集到的设备读数都会删掉。'
              '设置、启动统计和固定项都不受影响，之后会继续采集。',
              style: TextStyle(fontSize: 12.5, color: c.textSecondary),
            ),
          ),
          const SizedBox(width: 12),
          GhostButton(
            label: '取消',
            icon: Icons.undo_rounded,
            onTap: () => setState(() => _confirmingClear = false),
          ),
          const SizedBox(width: 8),
          GhostButton(
            label: '确认清空',
            icon: Icons.delete_forever_outlined,
            tone: GhostButtonTone.danger,
            onTap: () {
              metrics.clear();
              setState(() => _confirmingClear = false);
            },
          ),
        ],
      ),
    );
  }

  Widget _empty(AppColors c, MetricsProvider metrics) {
    final active = metrics.active;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.monitor_heart_outlined, size: 34, color: c.textMuted),
          const SizedBox(height: 16),
          Text(
            active ? '还没有采集到数据' : '设备信息采集没有启动',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            active
                ? '应用运行时会按设置里的采集间隔记下设备读数，这一页画出最近 7 天的曲线'
                : '历史数据库打不开，采集没有开始；重启应用再试一次',
            style: TextStyle(fontSize: 12.5, color: c.textMuted),
          ),
        ],
      ),
    );
  }

  /// The cards, two to a row once the window is wide enough for the charts to
  /// stay readable.
  Widget _grid(AppColors c) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 940 ? 2 : 1;
        final rows = <Widget>[];
        for (var i = 0; i < _cards.length; i += columns) {
          final slice =
              _cards.sublist(i, math.min(i + columns, _cards.length));
          rows.add(
            Row(
              // The cards carry their own height; inside a scroll view there is
              // none to stretch them to.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var j = 0; j < slice.length; j++) ...[
                  if (j > 0) const SizedBox(width: 16),
                  Expanded(child: _card(c, slice[j])),
                ],
                // A last row with one card keeps its width instead of
                // stretching across both columns.
                if (slice.length < columns) ...[
                  const SizedBox(width: 16),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ],
            ),
          );
          rows.add(const SizedBox(height: 14));
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.only(top: 16, bottom: 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        );
      },
    );
  }

  Widget _card(AppColors c, _ChartCardSpec spec) {
    final points = _points;
    // Two brushes for two readings: the accent every palette has, and the
    // semantic green, which no palette's accent is ever close to.
    final colors = [c.accent, c.ok];
    final series = [
      for (var i = 0; i < spec.fields.length; i++)
        MetricSeries(
          label: spec.fields[i].label,
          color: colors[i % colors.length],
          values: [for (final point in points) point[spec.fields[i]]],
        ),
    ];
    final times = [for (final point in points) point.time];
    final primary = spec.fields.first;
    final hasData =
        series.any((line) => line.values.any((value) => value != null));

    return Container(
      height: 226,
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(spec.icon, size: 14, color: c.textMuted),
              const SizedBox(width: 8),
              Text(
                spec.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
              const Spacer(),
              // The newest reading of each line, in that line's colour — the
              // legend under the chart says which is which.
              for (var i = 0; i < spec.fields.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Text(
                  spec.fields[i]
                      .format(MetricPoint.latest(points, spec.fields[i])),
                  style: TelemetryText.number(14, colors[i % colors.length]),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: hasData
                ? MetricChart(
                    series: series,
                    times: times,
                    ceiling: primary.ceiling,
                    decimals: primary.decimals,
                  )
                : Center(
                    child: Text(
                      '无数据',
                      style: TextStyle(fontSize: 12, color: c.textMuted),
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 0; i < spec.fields.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: colors[i % colors.length],
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '${spec.fields[i].label} '
                    '均 ${spec.fields[i].format(MetricPoint.mean(points, spec.fields[i]))}'
                    ' · 峰 ${spec.fields[i].format(MetricPoint.peak(points, spec.fields[i]))}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: c.textMuted),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// How long a stretch of history is, in the largest unit that still says
/// something. Rounds down, so "1 小时" never means fifty minutes.
String _duration(Duration span) {
  if (span.inMinutes < 1) return '不足 1 分钟';
  if (span.inHours < 1) return '${span.inMinutes} 分钟';
  if (span.inDays < 1) return '${span.inHours} 小时';
  return '${span.inDays} 天 ${span.inHours % 24} 小时';
}
