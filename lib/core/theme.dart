import 'package:flutter/material.dart';

/// Named palettes. Every color is a flat solid — no gradients anywhere.
enum PaletteId { violet, blue, cyan, lava }

class AppPalette {
  const AppPalette(
      this.id, this.name, this.accent, this.bg, this.surface, this.surfaceHover);

  final PaletteId id;
  final String name;
  final Color accent;
  final Color bg;
  final Color surface;
  final Color surfaceHover;
}

const appPalettes = <AppPalette>[
  AppPalette(PaletteId.violet, '竞技紫', Color(0xFF8B7CFF), Color(0xFF0E0D13),
      Color(0xFF17161F), Color(0xFF201E2B)),
  AppPalette(PaletteId.blue, '电光蓝', Color(0xFF4F8CFF), Color(0xFF0D1016),
      Color(0xFF151923), Color(0xFF1D2330)),
  AppPalette(PaletteId.cyan, '荧光青', Color(0xFF22D3EE), Color(0xFF0A1014),
      Color(0xFF111A1F), Color(0xFF17242B)),
  AppPalette(PaletteId.lava, '熔岩橙', Color(0xFFFF6B4A), Color(0xFF120E0C),
      Color(0xFF1C1614), Color(0xFF261D19)),
];

AppPalette paletteFor(PaletteId id) =>
    appPalettes.firstWhere((p) => p.id == id, orElse: () => appPalettes.first);

/// Themed design tokens shared across all palettes (semantic colors are
/// fixed; only accent + background tint change per palette).
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.accent,
    required this.bg,
    required this.surface,
    required this.surfaceHover,
    this.border = const Color(0x12FFFFFF),
    this.borderStrong = const Color(0x24FFFFFF),
    this.textPrimary = const Color(0xFFF2F3F7),
    this.textSecondary = const Color(0x99F2F3F7),
    this.textMuted = const Color(0x61F2F3F7),
    this.ok = const Color(0xFF34D399),
    this.warn = const Color(0xFFFBBF24),
    this.danger = const Color(0xFFF87171),
  });

  final Color accent;
  final Color bg;
  final Color surface;
  final Color surfaceHover;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color ok;
  final Color warn;
  final Color danger;

  Color get accentDim => accent.withValues(alpha: 0.14);
  Color get accentBright => accent;
  Color get barTrack => const Color(0x14FFFFFF);

  /// Fill of a frosted panel: the surface, thinned so the wallpaper keeps
  /// reading through the blur behind it. Dense enough that the content on top
  /// holds its contrast, thin enough that the glass still reads as glass over
  /// a dimmed wallpaper.
  Color get frost => surface.withValues(alpha: 0.52);

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? _fallback;

  static const _fallback = AppColors(
    accent: Color(0xFF8B7CFF),
    bg: Color(0xFF0E0D13),
    surface: Color(0xFF17161F),
    surfaceHover: Color(0xFF201E2B),
  );

  @override
  AppColors copyWith({
    Color? accent,
    Color? bg,
    Color? surface,
    Color? surfaceHover,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? ok,
    Color? warn,
    Color? danger,
  }) {
    return AppColors(
      accent: accent ?? this.accent,
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      ok: ok ?? this.ok,
      warn: warn ?? this.warn,
      danger: danger ?? this.danger,
    );
  }

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      accent: l(accent, other.accent),
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surfaceHover: l(surfaceHover, other.surfaceHover),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textMuted: l(textMuted, other.textMuted),
      ok: l(ok, other.ok),
      warn: l(warn, other.warn),
      danger: l(danger, other.danger),
    );
  }
}

AppColors colorsFor(AppPalette p) => AppColors(
      accent: p.accent,
      bg: p.bg,
      surface: p.surface,
      surfaceHover: p.surfaceHover,
    );

ThemeData buildTheme(AppPalette palette) {
  final c = colorsFor(palette);
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: c.bg,
    colorScheme: ColorScheme.dark(
      primary: c.accent,
      onPrimary: Colors.white,
      surface: c.surface,
      onSurface: c.textPrimary,
      error: c.danger,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    hoverColor: Colors.transparent,
    extensions: [c],
    fontFamily: null,
    textTheme: const TextTheme().apply(
      bodyColor: c.textPrimary,
      displayColor: c.textPrimary,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.surfaceHover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      textStyle: TextStyle(fontSize: 12, color: c.textPrimary),
      waitDuration: const Duration(milliseconds: 500),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surfaceHover),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: c.borderStrong),
          ),
        ),
      ),
    ),
  );
}
