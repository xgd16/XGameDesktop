import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/motion.dart';
import 'core/theme.dart';
import 'native/gamepad.dart';
import 'native/hwprobe_service.dart';
import 'state/apps_provider.dart';
import 'state/metrics_provider.dart';
import 'state/settings_provider.dart';
import 'state/weather_provider.dart';
import 'ui/home_screen.dart';

class XGameApp extends StatelessWidget {
  const XGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => HwprobeService()),
        ChangeNotifierProvider(create: (_) => MetricsProvider()),
        ChangeNotifierProvider(create: (_) => AppsProvider()),
        ChangeNotifierProvider(create: (_) => WeatherProvider()),
        ChangeNotifierProvider(create: (_) => GamepadService()),
      ],
      // Only the palette builds a theme. Watching the whole provider here would
      // rebuild MaterialApp and the theme on every slider move in the settings
      // page — the blur/dim sliders notify per pointer event.
      child: Selector<SettingsProvider, PaletteId>(
        selector: (_, settings) => settings.palette,
        builder: (context, palette, _) {
          final theme = buildTheme(paletteFor(palette));
          // AnimatedTheme eases every themed color (incl. the AppColors
          // extension) through a palette switch.
          return MaterialApp(
            title: 'XGame Desktop',
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: AnimatedTheme(
              data: theme,
              duration: Motion.theme,
              curve: Motion.outCubic,
              child: const HomeScreen(),
            ),
          );
        },
      ),
    );
  }
}
