import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../state/settings_provider.dart';
import 'nav.dart';

/// Inline palette switcher for the title bar: one dot per palette.
class ThemePicker extends StatelessWidget {
  const ThemePicker({super.key});

  @override
  Widget build(BuildContext context) {
    // The palette, not the whole provider: this sits in the title bar, and the
    // settings page notifies on every pointer move of its sliders.
    final palette = context.select<SettingsProvider, PaletteId>(
        (settings) => settings.palette);
    final settings = context.read<SettingsProvider>();
    return Row(
      children: [
        for (final p in appPalettes) ...[
          Tappable(
            onTap: () => settings.setPalette(p.id),
            tooltip: '主题颜色:${p.name}',
            builder: (context, state) => TouchTarget(
              minSize: const Size(34, 34),
              child: AnimatedContainer(
                duration: Motion.fast,
                curve: Motion.outCubic,
                width: 18,
                height: 18,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: palette == p.id
                        ? Colors.white
                        : state.focused
                            ? Colors.white70
                            : Colors.transparent,
                    width: 1.4,
                  ),
                ),
                child: Transform.scale(
                  scale: state.highlighted ? 1.15 : 1.0,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: p.accent,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }
}
