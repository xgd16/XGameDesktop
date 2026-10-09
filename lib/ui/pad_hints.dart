import 'package:flutter/material.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// The pad's cheat sheet: a thin strip along the bottom edge that says what
/// the buttons do, the way a console game does. It shows up when the pad is
/// used and slides away on its own a few seconds later — a mouse user with a
/// controller on the desk should never have to look at it.
class PadHints extends StatelessWidget {
  const PadHints({super.key, required this.visible});

  final bool visible;

  static const _hints = <(String, String)>[
    ('A', '启动'),
    ('B', '返回'),
    ('X', '应用区'),
    ('Y', '搜索'),
    ('LB RB', '切换视图'),
    ('View', '沉浸'),
    ('Start', '菜单/设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return IgnorePointer(
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, 0.5),
        duration: Motion.base,
        curve: Motion.outCubic,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: Motion.base,
          curve: Motion.outCubic,
          child: Frosted(
            radius: 20,
            blur: 18,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: c.frost,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: c.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sports_esports_outlined,
                      size: 15, color: c.textMuted),
                  for (final (key, label) in _hints) ...[
                    const SizedBox(width: 12),
                    _Chip(label: key),
                    const SizedBox(width: 5),
                    Text(label,
                        style: TextStyle(fontSize: 11.5, color: c.textSecondary)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.surfaceHover,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.borderStrong),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Rajdhani',
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: c.textPrimary,
        ),
      ),
    );
  }
}
