import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/native/gamepad.dart';
import 'package:xgame_desktop/native/hwprobe_service.dart';
import 'package:xgame_desktop/native/shell_apps.dart';
import 'package:xgame_desktop/native/window_shell.dart';
import 'package:xgame_desktop/state/app_activity.dart';
import 'package:xgame_desktop/state/apps_provider.dart';
import 'package:xgame_desktop/state/metrics_provider.dart';
import 'package:xgame_desktop/state/settings_provider.dart';
import 'package:xgame_desktop/state/weather_provider.dart';
import 'package:xgame_desktop/ui/app_card.dart';
import 'package:xgame_desktop/ui/apps_pane.dart';
import 'package:xgame_desktop/ui/context_menu.dart' show contextMenuKey;
import 'package:xgame_desktop/ui/home_screen.dart';
import 'package:xgame_desktop/ui/keyboard_overlay.dart';
import 'package:xgame_desktop/ui/metrics_panel.dart';
import 'package:xgame_desktop/ui/pad_hints.dart';
import 'package:xgame_desktop/ui/settings_page.dart';
import 'package:xgame_desktop/ui/title_bar.dart';

// XINPUT_GAMEPAD bitmasks, as the pad reports them.
const _dpadUp = 0x0001;
const _dpadDown = 0x0002;
const _dpadLeft = 0x0004;
const _dpadRight = 0x0008;
const _start = 0x0010;
const _backButton = 0x0020;
const _leftShoulder = 0x0100;
const _rightShoulder = 0x0200;
const _buttonA = 0x1000;
const _buttonB = 0x2000;
const _buttonX = 0x4000;
const _buttonY = 0x8000;

/// A pad the test drives by hand: set the fields, then poll.
class _FakePad {
  bool connected = true;
  int buttons = 0;
  double lx = 0;
  double ly = 0;
  int lt = 0;
  int rt = 0;

  GamepadReading? read(int slot) => connected && slot == 0
      ? GamepadReading(
          buttons: buttons,
          thumbLX: lx,
          thumbLY: ly,
          leftTrigger: lt,
          rightTrigger: rt,
        )
      : null;
}

/// A service whose polling is the test's job — no timers, no XInput. The
/// foreground check is stubbed open: these cases drive the shell, not Windows.
class _TestPad extends GamepadService {
  _TestPad(_FakePad pad)
      : super(sampler: pad.read, foreground: () => true);

  @override
  void start() {}
}

class _QuietApps extends AppsProvider {
  _QuietApps({required this.launched, super.dataDir})
      : super(
          launcher: _record(launched),
        );

  final List<String> launched;

  static bool Function(String) _record(List<String> log) => (path) {
        log.add(path);
        return true;
      };

  @override
  Future<void> load() async {}
}

class _QuietProbe extends HwprobeService {
  @override
  Future<void> start() async {}

  @override
  Future<void> shutdown() async {}
}

/// A probe that has already answered. The telemetry column and its scroll
/// area only exist once the backend reported, and there is nothing for the
/// pad to land on while the panel is still a spinner.
class _ReadyProbe extends HwprobeService {
  _ReadyProbe() {
    status = HwprobeStatus.ready;
  }

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
  group('手柄轮询', () {
    late _FakePad pad;
    late GamepadService service;
    late List<GamepadAction> log;
    var now = DateTime(2026);
    var foreground = true;

    setUp(() {
      pad = _FakePad();
      now = DateTime(2026);
      foreground = true;
      service = GamepadService(
        sampler: pad.read,
        foreground: () => foreground,
      )..clock = () => now;
      log = [];
      service.actions.listen(log.add);
    });

    tearDown(() => service.dispose());

    /// One poll, plus the microtask that carries the action to the listener.
    Future<void> poll() async {
      service.pollOnce();
      await Future<void>.delayed(Duration.zero);
    }

    test('XInput 绑定在本机装得上，没插手柄时四个槽位都是空的', () {
      if (!Platform.isWindows) return;
      for (var slot = 0; slot < 4; slot++) {
        // 不抛异常就说明绑定没问题：DLL 名、符号名、结构体布局。
        XInput.read(slot);
      }
      expect(XInput.loaded, isTrue);
    });

    test('按键只在按下的那一刻触发一次', () async {
      pad.buttons = _buttonA;
      await poll();
      expect(log, [GamepadAction.accept]);

      await poll();
      expect(log, [GamepadAction.accept], reason: '按住不该连发');

      pad.buttons = 0;
      await poll();
      pad.buttons = _buttonA;
      await poll();
      expect(log, [GamepadAction.accept, GamepadAction.accept]);
    });

    test('方向键按住先等一拍再连发', () async {
      pad.buttons = _dpadDown;
      await poll();
      expect(log, [GamepadAction.down]);

      now = now.add(const Duration(milliseconds: 200));
      await poll();
      expect(log, [GamepadAction.down], reason: '首拍延迟内不重复');

      now = now.add(const Duration(milliseconds: 400));
      await poll();
      now = now.add(const Duration(milliseconds: 100));
      await poll();
      expect(log, [
        GamepadAction.down,
        GamepadAction.down,
        GamepadAction.down,
      ]);
    });

    test('左摇杆有死区，且一次只认一个主方向', () async {
      pad.ly = 0.2;
      await poll();
      expect(log, isEmpty, reason: '死区内不产生方向');

      pad.ly = 0.9;
      await poll();
      expect(log, [GamepadAction.up]);

      pad.ly = -0.9;
      await poll();
      expect(log, [GamepadAction.up, GamepadAction.down]);

      // 斜推时主轴领先，不该两边一起触发
      pad.lx = 0.95;
      pad.ly = 0.9;
      await poll();
      expect(log.last, GamepadAction.right);
      expect(log.length, 3);
    });

    test('松开方向再推回去会立刻重新触发', () async {
      pad.buttons = _dpadRight;
      await poll();
      pad.buttons = 0;
      await poll();
      pad.buttons = _dpadRight;
      await poll();
      expect(log, [GamepadAction.right, GamepadAction.right]);
    });

    test('扳机翻页，按住会重复', () async {
      pad.rt = 200;
      await poll();
      expect(log, [GamepadAction.pageDown]);

      now = now.add(const Duration(milliseconds: 500));
      await poll();
      expect(log, [GamepadAction.pageDown, GamepadAction.pageDown]);

      pad.rt = 0;
      await poll();
      pad.lt = 255;
      await poll();
      expect(log.last, GamepadAction.pageUp);
    });

    test('ABXY、肩键、Start/View 各归各位', () async {
      for (final (mask, action) in [
        (_buttonB, GamepadAction.back),
        (_buttonX, GamepadAction.grid),
        (_buttonY, GamepadAction.search),
        (_backButton, GamepadAction.immersive),
        (_start, GamepadAction.menu),
        (_leftShoulder, GamepadAction.tabPrev),
        (_rightShoulder, GamepadAction.tabNext),
      ]) {
        pad.buttons = mask;
        await poll();
        pad.buttons = 0;
        await poll();
        expect(log.last, action, reason: '掩码 $mask');
      }
    });

    test('热插拔：拔掉后报告未连接，插回来能重新找到', () async {
      await poll();
      expect(service.connected, isTrue);

      pad.connected = false;
      await poll();
      expect(service.connected, isFalse);
      expect(log, isEmpty);

      pad.connected = true;
      await poll();
      expect(service.connected, isTrue);
    });

    test('窗口不在前台时手柄静默，回到前台要重新按', () async {
      pad.buttons = _buttonA;
      await poll();
      expect(log, [GamepadAction.accept]);

      // 别的窗口在前台——通常就是刚从这里启动的游戏。XInput 谁都能读，
      // 但那一刻手柄是那个窗口的，按住的东西也不能跨过暂停活下去。
      foreground = false;
      await poll();
      expect(log, [GamepadAction.accept], reason: '失焦后不派发任何动作');

      foreground = true;
      await poll();
      expect(log, [GamepadAction.accept, GamepadAction.accept],
          reason: '回前台后按住的手柄算一次新的按下，而不是半路丢掉的那一次');
    });

    test('最小化时同样静默', () async {
      addTearDown(() => AppActivity.update(AppLifecycleState.resumed));

      AppActivity.update(AppLifecycleState.hidden);
      pad.buttons = _buttonA;
      await poll();
      expect(log, isEmpty, reason: '看不见的窗口接手柄动作毫无意义');
    });
  });

  group('手柄导航', () {
    late Directory dataDir;
    late _FakePad pad;
    late _TestPad service;
    late _QuietApps apps;
    late SettingsProvider settings;
    late List<String> launched;

    /// A provider over the temp data dir, released with the test. It holds the
    /// profile database open, and Windows will not delete the directory until
    /// it lets go.
    SettingsProvider tracked() {
      final settings = SettingsProvider(dataDir: dataDir);
      addTearDown(settings.dispose);
      return settings;
    }

    setUp(() {
      dataDir = Directory.systemTemp.createTempSync('xg_pad');
      pad = _FakePad();
      service = _TestPad(pad);
      launched = [];
      settings = tracked()
        ..wallpaperEngineLocator = () => null;
      apps = _QuietApps(launched: launched, dataDir: dataDir)
        ..apps = [
          AppEntry(
              name: 'Steam', path: r'C:\Start Menu\Steam.lnk', hasDesktop: true),
          AppEntry(
              name: 'Chrome',
              path: r'C:\Start Menu\Chrome.lnk',
              hasDesktop: true),
        ]
        // 推荐 tab starts out empty (nothing has been launched yet), and a
        // focus test needs tiles on screen.
        ..view = AppsView.desktop
        ..status = AppsStatus.ready;
      // A launch from these tests opens the profile database, so the app
      // provider has to let go of it before the directory is deleted.
      addTearDown(apps.dispose);
    });

    tearDown(() {
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> pumpHome(
      WidgetTester tester, {
      HwprobeService? probe,
      Size size = const Size(1400, 900),
      double dpr = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider<AppsProvider>.value(value: apps),
            ChangeNotifierProvider<MetricsProvider>.value(
                value: _QuietMetrics(dataDir: dataDir)),
            ChangeNotifierProvider<HwprobeService>.value(
                value: probe ?? _QuietProbe()),
            ChangeNotifierProvider<WeatherProvider>.value(
                value: _QuietWeather()),
            ChangeNotifierProvider<GamepadService>.value(value: service),
          ],
          child: MaterialApp(
            theme: buildTheme(appPalettes.first),
            // These cases drive the shell, not the opening screen: the boot
            // screen holds the pad's input until the catalog has loaded, and
            // nothing here loads one. It has its own tests.
            home: const HomeScreen(bootScreen: false),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    /// Presses [buttons], lets the action travel, settles what it started, and
    /// lets the hint strip's own timer expire so no timer outlives the test.
    Future<void> press(WidgetTester tester, int buttons) async {
      pad.buttons = buttons;
      service.pollOnce();
      pad.buttons = 0;
      await tester.pump();
      service.pollOnce();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('推一下方向键，第一块磁贴获得焦点，A 启动它', (tester) async {
      await pumpHome(tester);
      expect(launched, isEmpty);

      await press(tester, _dpadDown);
      await press(tester, _buttonA);

      expect(launched, [apps.visibleApps.first.path],
          reason: '方向键把焦点交给网格里的第一块磁贴，A 就是 Enter');
    });

    testWidgets('Y 打开屏幕键盘，点一个字母就进了搜索框', (tester) async {
      await pumpHome(tester);
      expect(find.byType(SoftKeyboard), findsNothing);

      await press(tester, _buttonY);
      expect(find.byType(SoftKeyboard), findsOneWidget);

      await tester.tap(find.descendant(
          of: find.byType(SoftKeyboard), matching: find.text('A')));
      await tester.pump();
      expect(apps.query, 'a');

      // B 的第一个去处就是键盘本身。
      await press(tester, _buttonB);
      expect(find.byType(SoftKeyboard), findsNothing);
    });

    testWidgets('Start 开设置页，B 关掉它', (tester) async {
      await pumpHome(tester);

      await press(tester, _start);
      expect(find.byType(SettingsPage), findsOneWidget);

      await press(tester, _buttonB);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SettingsPage), findsNothing);
    });

    testWidgets('LB/RB 在推荐与桌面之间切换', (tester) async {
      await pumpHome(tester);
      expect(apps.view, AppsView.desktop);

      await press(tester, _rightShoulder);
      expect(apps.view, AppsView.recommended, reason: '两个视图循环');

      await press(tester, _leftShoulder);
      expect(apps.view, AppsView.desktop);
    });

    testWidgets('切到更短的视图，高亮落到还存在的磁贴上而不是消失', (tester) async {
      // 推荐视图只有一个（启动过一次的）图标，桌面视图有两个。
      apps.launch(apps.apps.first);
      expect(apps.recommendedCount, 1);
      await pumpHome(tester);

      await press(tester, _dpadDown);
      await press(tester, _dpadRight);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app1');

      await press(tester, _leftShoulder);
      expect(apps.view, AppsView.recommended);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0',
          reason: '原来那一格新视图放不下，高亮落到最后一块磁贴上');
    });

    testWidgets('切到空的视图，高亮落在搜索框上而不是消失', (tester) async {
      await pumpHome(tester);
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');

      // 推荐视图一个图标都没有：磁贴全部消失，高亮得有个去处。
      await press(tester, _leftShoulder);
      expect(apps.view, AppsView.recommended);
      expect(apps.visibleApps, isEmpty);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search');
    });

    testWidgets('键盘开着时切换视图，高亮留在键盘上', (tester) async {
      await pumpHome(tester);
      await press(tester, _buttonY);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kb1');

      await press(tester, _rightShoulder);
      expect(apps.view, AppsView.recommended);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kb1',
          reason: '高亮不在网格上，切视图不该把它拽走');
    });

    testWidgets('View 进出沉浸模式，B 在顶层不再顺手把它退掉', (tester) async {
      await pumpHome(tester);
      expect(find.byKey(const Key('immersiveZoom')), findsNothing);

      await press(tester, _backButton);
      expect(find.byKey(const Key('immersiveZoom')), findsOneWidget);

      // 顶层没有浮层可关，B 就什么都不做——沉浸模式不能是一次误按的距离。
      await press(tester, _buttonB);
      expect(find.byKey(const Key('immersiveZoom')), findsOneWidget);

      await press(tester, _backButton);
      expect(find.byKey(const Key('immersiveZoom')), findsNothing);
    });

    testWidgets('进沉浸模式时高亮留在原地，Esc 照样退得出来', (tester) async {
      await pumpHome(tester);
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');

      await press(tester, _backButton);
      expect(find.byKey(const Key('immersiveZoom')), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0',
          reason: '高亮不该在进沉浸时被丢到整窗节点上');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('immersiveZoom')), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');
    });

    testWidgets('融进任务栏的沉浸模式里，提示条抬到任务栏上面', (tester) async {
      // 2× 缩放屏：任务栏 96 物理像素，也就是 48 逻辑像素。
      await pumpHome(tester, size: const Size(2800, 1800), dpr: 2);

      // 提示条是整窗唯一的 Positioned 浮层，量它的落点就是量提示条。
      double fromBottom() => 900 -
          tester
              .getRect(find.ancestor(
                  of: find.byType(PadHints),
                  matching: find.byType(Positioned)))
              .bottom;

      expect(fromBottom(), closeTo(14, 0.5),
          reason: '窗口模式贴着窗口底边，任务栏在窗口外面');

      WindowShell.debugBottomInsetOverride = 96;
      addTearDown(() => WindowShell.debugBottomInsetOverride = null);

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pump();

      expect(fromBottom(), closeTo(14 + 48, 0.5),
          reason: '窗口垫到任务栏下面后，提示条要让开任务栏那 48 逻辑像素');
    });

    testWidgets('搜索框有焦点时，F11 与 Esc 仍然有效', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search');

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('immersiveZoom')), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search',
          reason: '按键从任意焦点向上冒泡到整窗节点，不需要把高亮拽走');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('immersiveZoom')), findsNothing);
      // Leaving immersive re-runs the Entrance callbacks under the
      // magnifier's MediaQuery; let their zero-delay timers fire.
      await tester.pump(const Duration(milliseconds: 600));
    });

    /// Whether the pad's highlight sits inside a widget of type [type].
    bool focusedInside(Type type) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return false;
      return find
          .ancestor(
            of: find.byElementPredicate(
                (element) => identical(element, context)),
            matching: find.byType(type),
          )
          .evaluate()
          .isNotEmpty;
    }

    testWidgets('从 title bar 向下落到搜索框，而不是掉进监控面板', (tester) async {
      await pumpHome(tester);
      await press(tester, _dpadDown); // 第一块磁贴
      await press(tester, _dpadUp); // 搜索框
      await press(tester, _dpadUp); // 标题栏里的主题圆点
      expect(focusedInside(TitleBar), isTrue, reason: '高亮确实到了栏里');

      // 沿栏内横着走：遍历历史不再把它送回搜索框，原来那个几何遍历于是
      // 落到圆点正下方——监控面板的滚动区，环就没了。
      for (var i = 0; i < 5; i++) {
        await press(tester, _dpadRight);
      }
      expect(focusedInside(TitleBar), isTrue, reason: '还在栏里（栏内按钮也一样）');

      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search',
          reason: '栏是横跨窗口的一条，向下就是页面第一行');
    });

    testWidgets('高亮落到监控面板上时，面板自己亮起来而不是没有提示', (tester) async {
      BoxDecoration panel() => tester
          .widget<Container>(find
              .descendant(
                  of: find.byType(MetricsPanel),
                  matching: find.byType(Container))
              .first)
          .decoration! as BoxDecoration;

      await pumpHome(tester, probe: _ReadyProbe());
      expect(panel().color, isNull, reason: '没高亮时面板安静地贴在墙上');

      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'telemetry',
          reason: '一行磁贴下面就是监控面板');
      expect(panel().color, isNotNull, reason: '面板拿到高亮要亮起来');
      expect((panel().border! as Border).left.width, greaterThan(1),
          reason: '竖边也要变粗，边缘那根线才读得出来');

      await press(tester, _dpadLeft);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0',
          reason: '面板不吞左右，往回走还是回到网格');
      expect(panel().color, isNull, reason: '高亮走了，面板恢复安静');
    });

    testWidgets('分段开关和字段里的图标按钮，拿到高亮也画出强调色的环', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search');

      /// The ring the box a control draws around itself has. That box is the
      /// [Tappable] builder's child, so it hangs *below* the focus node, not
      /// above it — an ancestor lookup would find the search field's own box
      /// instead and call its border this control's ring.
      Color ring() {
        final context = FocusManager.instance.primaryFocus!.context!;
        final box = tester.widget<AnimatedContainer>(find
            .descendant(
                of: find.byElementPredicate(
                    (element) => identical(element, context)),
                matching: find.byType(AnimatedContainer))
            .first);
        return ((box.decoration as BoxDecoration).border! as Border).top.color;
      }

      await press(tester, _dpadRight);
      expect(
          FocusManager.instance.primaryFocus!.rect
              .contains(tester.getRect(find.byTooltip('屏幕键盘')).center),
          isTrue,
          reason: '字段里的图标按钮');
      expect(ring(), appPalettes.first.accent,
          reason: '图标只换个深浅，手柄读起来就像高亮丢了');

      await press(tester, _dpadRight);
      expect(
          FocusManager.instance.primaryFocus!.rect
              .contains(tester.getRect(find.textContaining('推荐')).center),
          isTrue,
          reason: '分段开关');
      expect(ring(), appPalettes.first.accent,
          reason: '分段开关原来只有文字变色，也一样');
    });

    testWidgets('进沉浸模式再出来，标题栏上的高亮还是原来那个', (tester) async {
      // 够大的窗口：沉浸模式真的在缩放整页，切换时整棵 shell 会被换掉。
      await pumpHome(tester, size: const Size(2560, 1440));
      await press(tester, _dpadDown); // 第一块磁贴
      await press(tester, _dpadUp); // 搜索框
      await press(tester, _dpadUp); // 标题栏里的主题圆点
      expect(focusedInside(TitleBar), isTrue);
      final bar = FocusManager.instance.primaryFocus;

      await press(tester, _backButton);
      expect(find.byKey(const Key('immersiveZoom')), findsOneWidget);
      expect(identical(FocusManager.instance.primaryFocus, bar), isTrue,
          reason: '沉浸只是把这一页放大，栏不该被重建成新的高亮');

      await press(tester, _backButton);
      expect(find.byKey(const Key('immersiveZoom')), findsNothing);
      expect(identical(FocusManager.instance.primaryFocus, bar), isTrue,
          reason: '退出来也一样');
    });

    testWidgets('进沉浸模式，监控面板上的高亮也留得住', (tester) async {
      await pumpHome(tester,
          probe: _ReadyProbe(), size: const Size(2560, 1440));
      await press(tester, _dpadDown);
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'telemetry');
      final panel = FocusManager.instance.primaryFocus;

      await press(tester, _backButton);
      expect(identical(FocusManager.instance.primaryFocus, panel), isTrue,
          reason: '面板的滚动区要跟着整页一起搬过去，不能被重建');
    });

    testWidgets('页面背后换过视图，关掉页面时高亮不会停在看不见的节点上', (tester) async {
      apps.launch(apps.apps.first); // 推荐视图里也放一块，关页面后得有地方去
      await pumpHome(tester);
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');

      await press(tester, _start); // 开页面
      // 页面开着时切视图：原来记住的那块磁贴随桌面视图一起没了。
      await press(tester, _leftShoulder);
      expect(apps.view, AppsView.recommended);

      await press(tester, _buttonB); // 关页面
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      final node = FocusManager.instance.primaryFocus;
      expect(node?.debugLabel, isNot('home'),
          reason: '整窗节点上不画任何东西：高亮停在那儿就是"光标没了"');
      expect(node?.parent, isNotNull, reason: '而且它得真的挂在树上');
      expect(focusedInside(AppsPane), isTrue,
          reason: '高亮要回到看得见的磁贴或搜索框上');
    });

    testWidgets('拿着高亮的磁贴被列表变化拿掉，高亮会找下一个落脚点', (tester) async {
      await pumpHome(tester);
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');

      // 列表在背后变了（刷新、过滤……都一样）：这块磁贴整个消失。
      apps.setQuery('chrome');
      await tester.pump();
      await tester.pump();

      final node = FocusManager.instance.primaryFocus;
      expect(node?.debugLabel, isNot('home'),
          reason: '不能把高亮丢在整窗节点上，那儿没有环');
      expect(focusedInside(AppsPane), isTrue);
    });

    testWidgets('设置页里向下按阅读顺序走，一路到底也不会掉出画面', (tester) async {
      await pumpHome(tester);
      await press(tester, _start);
      await press(tester, _dpadDown); // 第一格：页面右上角的关闭按钮

      final seen = <String>{};
      final tops = <double>[];
      final labels = <String?>[];
      for (var i = 0; i < 18; i++) {
        final node = FocusManager.instance.primaryFocus;
        expect(node?.parent, isNotNull, reason: '第 $i 步：高亮要挂在树上');
        seen.add('${node?.debugLabel}/${node?.rect.top}');
        tops.add(node!.rect.top);
        labels.add(node.debugLabel);
        final rect = node.rect;
        expect(rect.top, greaterThanOrEqualTo(40),
            reason: '第 $i 步：高亮不能跑到页面上面去');
        expect(rect.bottom, lessThanOrEqualTo(900),
            reason: '第 $i 步：高亮不能在窗口外面');
        await press(tester, _dpadDown);
      }

      expect(seen.length, greaterThanOrEqualTo(10),
          reason: '几何遍历只会找到右边那一列按钮，中间那些开关和滑块都得能走到');
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i], greaterThanOrEqualTo(tops[i - 1] - 40),
            reason: '向下一格一格走，不该往回跳（第 $i 步）');
      }
      // 走到最后一格就停住：不能绕回页面上边看不见的地方。
      expect(labels.last, labels[labels.length - 2]);
    });

    testWidgets('滑块拿到高亮时整行画环，左右推杆调值', (tester) async {
      await pumpHome(tester);
      final before = settings.backgroundDim;

      await press(tester, _start);
      for (var i = 0; i < 7; i++) {
        await press(tester, _dpadDown);
      }
      final node = FocusManager.instance.primaryFocus;
      expect(node?.debugLabel, 'slider', reason: '走到第一个滑块上');

      /// Whether an accent border is painted above the focused node.
      final element = node!.context! as Element;
      var ringed = false;
      element.visitAncestorElements((ancestor) {
        final box = ancestor.renderObject;
        if (box is RenderDecoratedBox) {
          final decoration = box.decoration;
          if (decoration is BoxDecoration &&
              decoration.border is Border &&
              ((decoration.border! as Border).top.color ==
                  appPalettes.first.accent)) {
            ringed = true;
            return false;
          }
        }
        return true;
      });
      expect(ringed, isTrue, reason: '滑块自己什么都不画，环得由这一行来画');

      await press(tester, _dpadRight);
      expect(settings.backgroundDim, greaterThan(before),
          reason: '左右推杆就是调这个值');
    });

    /// Which tiles currently paint the highlight hairline, in grid order. A
    /// [Tappable] highlights for the pointer and for the pad alike, so this is
    /// where "two selections at once" shows up.
    List<int> highlighted(WidgetTester tester) {
      final cards = find.byType(AppCard);
      final marked = <int>[];
      for (var i = 0; i < cards.evaluate().length; i++) {
        final box = tester.widget<AnimatedContainer>(find
            .descendant(
                of: cards.at(i), matching: find.byType(AnimatedContainer))
            .first);
        final border = (box.decoration! as BoxDecoration).border! as Border;
        if (border.top.color != Colors.transparent) marked.add(i);
      }
      return marked;
    }

    testWidgets('鼠标停在一块磁贴上，手柄拿走高亮后只剩一块亮着', (tester) async {
      await pumpHome(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(AppCard).at(1)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(highlighted(tester), [1], reason: '指针底下的那块亮着');

      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');
      expect(highlighted(tester), [0],
          reason: '手柄把高亮拿走之后，指针停着的那块不能继续当成第二个选中');

      // 指针自己一动，悬停立刻回来——那是鼠标在驾驶，两个高亮是它自己造成的。
      await mouse.moveBy(const Offset(4, 4));
      await tester.pump(const Duration(milliseconds: 400));
      expect(highlighted(tester), [0, 1]);
    });

    testWidgets('鼠标点一下自己悬停的磁贴，悬停不该跟着消失', (tester) async {
      await pumpHome(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      final target = tester.getCenter(find.byType(AppCard).at(1));
      await mouse.moveTo(target);
      await tester.pump(const Duration(milliseconds: 400));
      expect(highlighted(tester), [1]);

      // 点击会把手柄的环策略交还给框架（highlightStrategy 回到 automatic），
      // 那也是 FocusManager 的一次通知——但高亮没有移动，指针自己的悬停得留着。
      await mouse.down(target);
      await tester.pump(const Duration(milliseconds: 100));
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(highlighted(tester), [1], reason: '指针还停在那儿，它自己没让位给谁');

      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Start 在磁贴上是磁贴的菜单，别处仍是设置页', (tester) async {
      await pumpHome(tester);
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');

      await press(tester, _start);
      expect(find.byKey(contextMenuKey), findsOneWidget,
          reason: 'Start 在磁贴上弹出该磁贴的右键菜单（钉选、打开文件位置）');
      await press(tester, _buttonB);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(contextMenuKey), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0',
          reason: '菜单收起，高亮回到磁贴');

      // 高亮不在磁贴上时，Start 还是原来的设置页。
      await press(tester, _dpadUp);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search');
      await press(tester, _start);
      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('打开设置页，高亮进入页面；A 不会打到背后的磁贴', (tester) async {
      await pumpHome(tester);
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'app0');

      // Start 在磁贴上已经归了磁贴的菜单，设置页从搜索栏那边按 Start 进来——
      // 这条要保的是"页面开着时 A 不泄漏给背后的磁贴"。
      await press(tester, _dpadUp);
      await press(tester, _start);
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(focusedInside(SettingsPage), isTrue,
          reason: '高亮跟着页面走，而不是留在页面背后');

      await press(tester, _buttonA);
      expect(launched, isEmpty, reason: 'A 不能按到页面背后那块磁贴上');

      for (var i = 0; i < 3; i++) {
        await press(tester, _dpadDown);
        expect(focusedInside(SettingsPage), isTrue,
            reason: '方向键在页面里走，不钻到页面背后');
      }

      await press(tester, _buttonB);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SettingsPage), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search',
          reason: '关掉页面，高亮回到开页面之前的地方');
    });

    testWidgets('键盘开着时打开设置页，高亮也跟着进页面', (tester) async {
      await pumpHome(tester);
      await press(tester, _dpadDown);
      await press(tester, _buttonY); // 屏幕键盘
      expect(find.byType(SoftKeyboard), findsOneWidget);

      await press(tester, _start);
      expect(find.byType(SoftKeyboard), findsNothing, reason: '页面盖住键盘，键盘就该收起');
      expect(focusedInside(SettingsPage), isTrue, reason: '向下不该把高亮送进看不见的键盘');
    });

    testWidgets('X 把高亮送回应用图标区，键盘挡路时先收起键盘', (tester) async {
      await pumpHome(tester);

      await press(tester, _buttonY);
      expect(find.byType(SoftKeyboard), findsOneWidget);

      await press(tester, _buttonX);
      expect(find.byType(SoftKeyboard), findsNothing);

      // 高亮落在第一块磁贴上：A 就是 Enter。
      await press(tester, _buttonA);
      expect(launched, [apps.visibleApps.first.path]);
    });

    testWidgets('搜索框有焦点、键盘没开时，摇杆向下直接进应用区', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search');

      await press(tester, _dpadDown);
      final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
      expect(label, startsWith('app'),
          reason: '文本框自己的方向动作会吞掉默认意图，摇杆必须能从搜索框里出来');
    });

    testWidgets('键盘开着时，摇杆向下直接落到第一个按键上，A 输入', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await press(tester, _buttonY);
      expect(find.byType(SoftKeyboard), findsOneWidget);
      // 实体键盘还在往搜索框里打字，焦点留在原地。
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search');

      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kb1',
          reason: '向下落在键盘第一排，而不是被遍历历史弹回搜索框');

      await press(tester, _buttonA);
      expect(apps.query, '1', reason: 'A 在按键上就是输入');
    });

    testWidgets('键盘上逐键移动，顶排向上回搜索框，向下再进键盘', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await press(tester, _buttonY);

      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kb1');
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kbQ',
          reason: '向下走一行');
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kbA');
      await press(tester, _dpadRight);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kbS');
      await press(tester, _dpadUp);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kbW');
      await press(tester, _dpadUp);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kb2');
      await press(tester, _dpadUp);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search',
          reason: '顶排再向上就是搜索框');
      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kb1',
          reason: '回搜索框后再向下，还是从键盘顶上开始');
    });

    testWidgets('键盘里一路向下走到底排也不会离开键盘', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await press(tester, _buttonY);

      for (var i = 0; i < 7; i++) {
        await press(tester, _dpadDown);
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kb空格',
          reason: '五行走到底，再向下就停住，不去碰右边的监控面板');
    });

    testWidgets('高亮不在键盘上时，向下把它交给键盘', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await press(tester, _buttonY);

      // 搜索框右边的屏幕键盘按钮：焦点的确不在键盘上。
      await press(tester, _dpadRight);
      expect(FocusManager.instance.primaryFocus?.debugLabel, isNot(startsWith('kb')));

      await press(tester, _dpadDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'kb1');
    });
  });
}
