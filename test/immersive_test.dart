import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/native/gamepad.dart';
import 'package:xgame_desktop/native/hwprobe_service.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/state/apps_provider.dart';
import 'package:xgame_desktop/state/metrics_provider.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/state/weather_provider.dart';
import 'package:xgame_desktop/ui/home_screen.dart';
import 'package:xgame_desktop/ui/settings_page.dart';
import 'package:xgame_desktop/ui/title_bar.dart';

/// The real providers reach for the machine: a native poller, a Start-menu
/// scan, a weather request. Immersive plumbing only needs them present and
/// quiet, so these drop the work the screen kicks off at startup.
class _QuietApps extends AppsProvider {
  _QuietApps({super.dataDir}) : super(launcher: (_) => true);

  @override
  Future<void> load() async {}
}

class _QuietProbe extends HwprobeService {
  @override
  Future<void> start() async {}

  @override
  Future<void> shutdown() async {}
}

class _QuietWeather extends WeatherProvider {
  @override
  void start() {}
}

/// No pad, no timer.
class _QuietPad extends GamepadService {
  @override
  void start() {}
}

/// The recorder reaches for the machine's profile database; the shell only
/// needs it present here (the monitoring page has its own tests).
class _QuietMetrics extends MetricsProvider {
  _QuietMetrics({super.dataDir});

  @override
  void start({Duration? interval}) {}
}

void main() {
  late Directory dataDir;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_immersive');
  });

  tearDown(() {
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A provider over the temp data dir, released with the test. It holds the
  /// profile database open, and Windows will not delete the directory until it
  /// lets go.
  SettingsProvider tracked() {
    final settings = SettingsProvider(dataDir: dataDir);
    addTearDown(settings.dispose);
    return settings;
  }

  SettingsProvider newSettings() =>
      tracked()
        // Keeps the Wallpaper Engine section off this machine's installation.
        ..wallpaperEngineLocator = () => null;

  testWidgets('the title bar carries the immersive entry', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: newSettings(),
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(
            body: TitleBar(onImmersive: () => toggles++, onToggleSettings: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('沉浸模式 (F11)'));
    await tester.pump();
    expect(toggles, 1);
    expect(find.byIcon(Icons.horizontal_rule), findsOneWidget);
  });
  testWidgets('F11 magnifies the same page, Esc brings it back',
      (tester) async {
    // The magnification is the screen width over the shell's 1600 px layout:
    // 2400 → 1.5×.
    tester.view.physicalSize = const Size(2400, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final apps = _QuietApps(dataDir: dataDir)
      ..apps = [
        AppEntry(name: 'Steam', path: r'C:\Start Menu\Steam.lnk', hasDesktop: true),
      ]
      ..status = AppsStatus.ready;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: newSettings()),
          ChangeNotifierProvider<AppsProvider>.value(value: apps),
          ChangeNotifierProvider<MetricsProvider>.value(
              value: _QuietMetrics(dataDir: dataDir)),
          ChangeNotifierProvider<HwprobeService>.value(value: _QuietProbe()),
          ChangeNotifierProvider<WeatherProvider>.value(value: _QuietWeather()),
          ChangeNotifierProvider<GamepadService>.value(value: _QuietPad()),
        ],
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          // The opening screen holds the pad's input until the catalog has
          // loaded; this case is about the frame, not the boot.
          home: const HomeScreen(bootScreen: false),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const Key('immersiveZoom')), findsNothing);
    final framed = tester.getRect(find.byType(TitleBar)).height;

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Not a second page: the same bar, 1.5× closer, and the window buttons
    // that belong to a frame are gone.
    expect(find.byKey(const Key('immersiveZoom')), findsOneWidget);
    expect(tester.getRect(find.byType(TitleBar)).height,
        closeTo(framed * 1.5, 0.5));
    expect(find.byTooltip('退出沉浸模式 (F11)'), findsOneWidget);
    expect(find.byIcon(Icons.horizontal_rule), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.byKey(const Key('immersiveZoom')), findsNothing);
    expect(tester.getRect(find.byType(TitleBar)).height, closeTo(framed, 0.5));
    expect(find.byIcon(Icons.horizontal_rule), findsOneWidget);

    // Entering and leaving re-runs the Entrance dependency callbacks under the
    // magnifier's MediaQuery; let their zero-delay timers fire before the
    // fake clock stops.
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('the settings page offers immersive mode and remembers it',
      (tester) async {
    tester.view.physicalSize = const Size(1500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = newSettings();

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: Scaffold(
            body: SettingsPage(onClose: () {}, onEnterImmersive: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(settings.immersiveOnLaunch, isFalse);
    // The section sits inside the 1100 px view this test sets up, so the
    // switch is tappable without scrolling.
    await tester.tap(find.byKey(const Key('immersiveOnLaunch')));
    await tester.pumpAndSettle();
    expect(settings.immersiveOnLaunch, isTrue);

    // A restart reads the switch back from disk. Real file I/O has to run
    // outside the fake async zone the widget test lives in.
    final reloaded = tracked();
    await tester.runAsync(reloaded.load);
    expect(reloaded.immersiveOnLaunch, isTrue);
  });
}
