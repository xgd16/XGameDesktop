import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/typography.dart';
import '../data/app_activity_store.dart';
import '../native/shell_apps.dart';
import '../state/apps_provider.dart';
import 'widgets.dart';

/// The launch statistics: how often each app has been opened, most opened
/// first, with the two timestamps the `app_usage` table keeps.
///
/// Built like the settings page — a full-bleed surface over the shell, a
/// header with one action and a close button, and its own focus scope — so the
/// pad, the keyboard and a finger all leave it the same way they entered.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.onClose, this.focusNode});

  final VoidCallback onClose;

  /// The page's own focus scope, supplied by the shell so it can hand the pad's
  /// highlight to the page the moment it opens.
  final FocusNode? focusNode;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  /// 清空统计 has been pressed once. The second press is the one that drops the
  /// history — the app draws its own chrome everywhere and has no dialog, so
  /// the confirmation is a bar inside the page.
  bool _confirmingClear = false;

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

  void _clear(AppsProvider apps) {
    apps.clearLaunchStats();
    setState(() => _confirmingClear = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final apps = context.watch<AppsProvider>();
    final history = apps.launchHistory;
    final total = apps.totalLaunches;

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
                  Row(
                    children: [
                      Text(
                        '启动统计',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                          color: c.textPrimary,
                        ),
                      ),
                      if (total > 0) ...[
                        const SizedBox(width: 12),
                        Text(
                          '共 $total 次',
                          style: TelemetryText.number(13, c.textSecondary),
                        ),
                      ],
                      const Spacer(),
                      GhostButton(
                        label: '清空统计',
                        icon: Icons.delete_outline_rounded,
                        tone: GhostButtonTone.danger,
                        // Nothing recorded: the button stays where it is, inert
                        // rather than hidden, so the header does not reflow.
                        onTap: total == 0
                            ? null
                            : () => setState(() => _confirmingClear = true),
                      ),
                      const SizedBox(width: 14),
                      PageCloseButton(
                        key: const Key('statsClose'),
                        tooltip: '关闭统计 (Esc)',
                        onTap: widget.onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_confirmingClear) _confirmBar(c, apps),
                  Container(height: 1, color: c.border),
                  Expanded(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 980),
                        child: history.isEmpty
                            ? _empty(c)
                            : _table(c, apps, history, total),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The second press 清空统计 asks for, and the way out of it.
  Widget _confirmBar(AppColors c, AppsProvider apps) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: c.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '清空后无法恢复：每一次启动记录都会删掉。固定到首页的应用不受影响。',
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
            onTap: () => _clear(apps),
          ),
        ],
      ),
    );
  }

  Widget _empty(AppColors c) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insights_rounded, size: 34, color: c.textMuted),
          const SizedBox(height: 16),
          Text(
            '还没有启动记录',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '从应用网格里打开一个应用，这里会记下它的次数、首次和最后启动时间',
            style: TextStyle(fontSize: 12.5, color: c.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _table(
    AppColors c,
    AppsProvider apps,
    List<LaunchRecord> history,
    int total,
  ) {
    // The bars are read against the leader, not against the total: one app
    // that has been opened a hundred times would flatten every other row to
    // nothing.
    final top = history.first.launches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 14),
          child: Row(
            children: [
              _StatTile(
                label: '总启动次数',
                value: '$total',
                valueStyle: TelemetryText.number(26, c.textPrimary),
              ),
              const SizedBox(width: 12),
              _StatTile(
                label: '记录的应用',
                value: '${history.length}',
                valueStyle: TelemetryText.number(26, c.textPrimary),
              ),
              const SizedBox(width: 12),
              _StatTile(
                label: '最常启动',
                value: history.first.displayName,
                hint: '${history.first.launches} 次',
                valueStyle: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
            ],
          ),
        ),
        _columnHeader(c),
        Container(height: 1, color: c.border),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 30),
            itemCount: history.length,
            itemBuilder: (context, i) => _HistoryRow(
              rank: i + 1,
              record: history[i],
              installed: apps.catalogEntry(history[i].key),
              fraction: history[i].launches / top,
              share: history[i].launches / total,
            ),
          ),
        ),
      ],
    );
  }

  Widget _columnHeader(AppColors c) {
    final style = TextStyle(fontSize: 11, color: c.textMuted);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: _rankWidth,
            child: Text('名次', style: style),
          ),
          const SizedBox(width: _iconWidth + 12),
          Expanded(child: Text('应用', style: style)),
          const SizedBox(width: 14),
          SizedBox(width: _barWidth, child: Text('对比', style: style)),
          const SizedBox(width: 12),
          SizedBox(
            width: _countWidth,
            child: Text('次数', textAlign: TextAlign.right, style: style),
          ),
          SizedBox(
            width: _shareWidth,
            child: Text('占比', textAlign: TextAlign.right, style: style),
          ),
          SizedBox(
            width: _timeWidth,
            child: Text('最后启动', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }
}

// The column widths, shared by the header and every row so the two line up.
const double _rankWidth = 34;
const double _iconWidth = 30;
const double _barWidth = 150;
const double _countWidth = 58;
const double _shareWidth = 52;
const double _timeWidth = 96;

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.rank,
    required this.record,
    required this.installed,
    required this.fraction,
    required this.share,
  });

  final int rank;
  final LaunchRecord record;

  /// The scanned entry, when the app is still installed — where the icon and
  /// the current name come from.
  final AppEntry? installed;

  /// The row's bar against the leader, and its share of every launch.
  final double fraction;
  final double share;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final name = installed?.name ?? record.displayName;
    final last = record.lastLaunch;

    return SizedBox(
      height: 44,
      child: Row(
        children: [
          SizedBox(
            width: _rankWidth,
            child: Text(
              '$rank',
              style: TelemetryText.number(13, c.textMuted),
            ),
          ),
          _AppIcon(entry: installed, name: name),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: installed == null ? c.textSecondary : c.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 14),
          _Bar(width: _barWidth, fraction: fraction),
          const SizedBox(width: 12),
          SizedBox(
            width: _countWidth,
            child: Text(
              '${record.launches}',
              textAlign: TextAlign.right,
              style: TelemetryText.number(15, c.textPrimary),
            ),
          ),
          SizedBox(
            width: _shareWidth,
            child: Text(
              '${(share * 100).round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ),
          SizedBox(
            width: _timeWidth,
            child: Text(
              last == null ? '—' : _ago(last),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The app's own icon when the catalog still has one, and a letter block when
/// it does not — an uninstalled app, or one whose icon never extracted.
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.entry, required this.name});

  final AppEntry? entry;
  final String name;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final file = entry?.iconFile;
    return SizedBox(
      width: _iconWidth,
      height: _iconWidth,
      child: file == null
          ? _letter(c)
          : Image.file(
              File(file),
              fit: BoxFit.contain,
              // The file can be gone — the icon cache is a cache.
              errorBuilder: (_, _, _) => _letter(c),
            ),
    );
  }

  Widget _letter(AppColors c) {
    final trimmed = name.trim();
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceHover,
        borderRadius: BorderRadius.circular(7),
      ),
      alignment: Alignment.center,
      child: Text(
        trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase(),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: c.textSecondary,
        ),
      ),
    );
  }
}

/// One row's share, drawn as a filled length of the track.
class _Bar extends StatelessWidget {
  const _Bar({required this.width, required this.fraction});

  final double width;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final radius = BorderRadius.circular(3);
    // A floor of a few pixels: an app opened once should still show a mark,
    // not round away to nothing.
    final filled = (width * fraction).clamp(4.0, width);
    return Stack(
      children: [
        Container(
          width: width,
          height: 6,
          decoration: BoxDecoration(color: c.barTrack, borderRadius: radius),
        ),
        Container(
          width: filled,
          height: 6,
          decoration: BoxDecoration(color: c.accent, borderRadius: radius),
        ),
      ],
    );
  }
}

/// A headline figure above the table.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.valueStyle,
    this.hint,
  });

  final String label;
  final String value;
  final TextStyle valueStyle;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 11.5, color: c.textMuted),
            ),
            const SizedBox(height: 7),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle,
            ),
            if (hint case final hint?) ...[
              const SizedBox(height: 3),
              Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: c.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// How long ago [time] was, in the largest unit that still says something.
/// Rounds down, so "1 小时前" never means fifty minutes.
String _ago(DateTime time) {
  final delta = DateTime.now().toUtc().difference(time);
  if (delta.inMinutes < 1) return '刚刚';
  if (delta.inHours < 1) return '${delta.inMinutes} 分钟前';
  if (delta.inDays < 1) return '${delta.inHours} 小时前';
  if (delta.inDays < 30) return '${delta.inDays} 天前';
  if (delta.inDays < 365) return '${delta.inDays ~/ 30} 个月前';
  return '${delta.inDays ~/ 365} 年前';
}
