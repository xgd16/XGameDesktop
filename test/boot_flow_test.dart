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
import 'package:xgame_desktop/ui/app_card.dart';
import 'package:xgame_desktop/ui/apps_pane.dart';
import 'package:xgame_desktop/ui/boot_splash.dart';
import 'package:xgame_desktop/ui/home_screen.dart';

// XINPUT_GAMEPAD bitmasks, as the pad reports them.
const _dpadDown = 0x0002;
const _buttonA = 0x1000;

/// A pad the test drives by hand: set the fields, then poll.
class _FakePad {
  int buttons = 0;

  GamepadReading? read(int slot) =>
      slot == 0 ? GamepadReading(buttons: buttons) : null;
}

/// A service whose polling is the test's job — no timers, no XInput. The
/// foreground check is stubbed open; the test process is never the window in
/// front, and these cases are about the shell, not Windows.
class _TestPad extends GamepadService {
  _TestPad(_FakePad pad)
      : super(sampler: pad.read, foreground: () => true);

  @override
  void start() {}
}

/// A catalog the test fills in by hand: nothing is scanned and nothing is
/// extracted, so each phase of the boot can be held where a case wants it.
class _BootApps extends AppsProvider {
  _BootApps({super.dataDir, required List<String> launched})
      : super(launcher: (path) {
          launched.add(path);
          return true;
        });

  /// The scan landing, the way [load] reports it.
  void finishScan(List<AppEntry> entries) {
    apps = entries;
    status = AppsStatus.ready;
    notifyListeners();
  }

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

/// The recorder reaches for the machine's profile database; the shell only
/// needs it present here (the monitoring page has its own tests).
class _QuietMetrics extends MetricsProvider {
  _QuietMetrics({super.dataDir});

  @override
  void start({Duration? interval}) {}
}

void main() {
  late Directory dataDir;
  late _FakePad pad;
  late _TestPad service;
  late _BootApps apps;
  late SettingsProvider settings;
  late List<String> launched;

  final steam = AppEntry(
    name: 'Steam',
    path: r'C:\Start Menu\Steam.lnk',
    hasDesktop: true,
  );
  final chrome = AppEntry(
    name: 'Chrome',
    path: r'C:\Start Menu\Chrome.lnk',
    hasDesktop: true,
  );

  /// A provider over the temp data dir, released with the test. It holds the
  /// profile database open, and Windows will not delete the directory until it
  /// lets go.
  SettingsProvider tracked() {
    final settings = SettingsProvider(dataDir: dataDir);
    addTearDown(settings.dispose);
    return settings;
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('xg_boot');
    pad = _FakePad();
    service = _TestPad(pad);
    launched = [];
    settings = tracked()
      ..wallpaperEngineLocator = () => null;
    // 「推荐」starts out empty by design (nothing has been launched yet), and
    // these cases need tiles on screen.
    apps = _BootApps(dataDir: dataDir, launched: launched)
      ..view = AppsView.desktop;
  });

  tearDown(() {
    service.dispose();
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The settings file is read for real, so the boot screen's first gate is
    // open before the shell builds; the phases under test are the catalog's.
    await tester.runAsync(settings.load);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AppsProvider>.value(value: apps),
          ChangeNotifierProvider<MetricsProvider>.value(
              value: _QuietMetrics(dataDir: dataDir)),
          ChangeNotifierProvider<HwprobeService>.value(value: _QuietProbe()),
          ChangeNotifierProvider<WeatherProvider>.value(value: _QuietWeather()),
          ChangeNotifierProvider<GamepadService>.value(value: service),
        ],
        child: MaterialApp(
          theme: buildTheme(appPalettes.first),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pressPad(WidgetTester tester, int buttons) async {
    pad.buttons = buttons;
    service.pollOnce();
    pad.buttons = 0;
    await tester.pump();
  }

  /// Long enough for the assembly, the hold, the split and the pieces to go,
  /// plus the frames the handover itself takes: the callbacks into the shell
  /// run after the frame they are raised in.
  Future<void> pumpBootOut(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 1800));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    await tester.pump();
  }

  /// The splash's own copy of a line — the shell behind it may be saying the
  /// same thing, which is the point.
  Finder splashText(String text) => find.descendant(
        of: find.byType(BootSplash),
        matching: find.text(text),
      );

  testWidgets('开屏动画盖住没装好的内容，装好了才交给 shell', (tester) async {
    await pumpHome(tester);

    expect(find.byType(BootSplash), findsOneWidget);
    expect(splashText('正在扫描已安装的应用…'), findsOneWidget,
        reason: '开屏自己说现在在装什么');
    expect(find.byType(AppsPane), findsOneWidget, reason: 'shell 已经在它背后加载了');

    // The scan lands while the assembly is still playing: the grid is built
    // behind the field, standing still.
    apps.finishScan([steam, chrome]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(BootSplash), findsOneWidget);
    expect(
      tester.widget<AppCard>(find.byType(AppCard).first).enterDelay,
      isNull,
      reason: '开屏还盖着，磁贴就不该自己先跑一遍入场',
    );

    await pumpBootOut(tester);
    expect(find.byType(BootSplash), findsNothing);
    expect(find.text('正在扫描已安装的应用…'), findsNothing,
        reason: '交接之后，连加载文案也该跟着开屏一起走');

    // The shell is live: the pad's first press lands on the first tile.
    await pressPad(tester, _dpadDown);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');
    // The hint strip's own timer has to expire before the test ends.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('开屏还在时手柄按键进不了 shell，但能把它请走', (tester) async {
    await pumpHome(tester);
    apps.finishScan([steam, chrome]);
    await tester.pump(const Duration(milliseconds: 100));

    // A is the user saying "enough", not a launch: the tile behind the field
    // must not be activated by a press nobody can see.
    await pressPad(tester, _buttonA);
    expect(launched, isEmpty);
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('app0'));

    await pumpBootOut(tester);
    expect(find.byType(BootSplash), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('键鼠也能把它请走，没装完也不拦着', (tester) async {
    await pumpHome(tester);
    expect(find.byType(BootSplash), findsOneWidget);

    // Nothing has loaded — the scan has not even landed — but the user asked.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    await pumpBootOut(tester);
    expect(find.byType(BootSplash), findsNothing);
    expect(find.text('正在扫描已安装的应用…'), findsOneWidget,
        reason: 'shell 接手，由它自己的加载态接着报进度');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('网格的入场波被压住，交接那一刻才从头扫一遍', (tester) async {
    apps.finishScan([steam, chrome]);

    Widget pane(bool revealed) => ChangeNotifierProvider<AppsProvider>.value(
          value: apps,
          // 毛玻璃会问设置“背后有没有壁纸”；这个用例只看入场波，
          // 没有壁纸，玻璃照规矩降级成半透明填充。
          child: ChangeNotifierProvider<SettingsProvider>.value(
            value: settings,
            child: MaterialApp(
              theme: buildTheme(appPalettes.first),
              home: Scaffold(body: AppsPane(revealed: revealed)),
            ),
          ),
        );

    await tester.pumpWidget(pane(false));
    await tester.pump();
    expect(
      tester.widget<AppCard>(find.byType(AppCard).first).enterDelay,
      isNull,
      reason: '压住的时候磁贴站在自己的位置上，不播入场',
    );

    await tester.pumpWidget(pane(true));
    await tester.pump();
    expect(
      tester.widget<AppCard>(find.byType(AppCard).at(1)).enterDelay,
      isNotNull,
      reason: '交接那一刻，第二块磁贴拿到第二拍的延迟——整屏从头扫一遍',
    );
    await tester.pumpAndSettle();
  });
}
