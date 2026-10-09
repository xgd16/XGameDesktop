import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/state/app_activity.dart';
import 'package:xgame_desktop/state/wallpaper_gate.dart';

void main() {
  tearDown(() {
    WallpaperGate.stop();
    WallpaperGate.probeOverride = null;
    AppActivity.update(AppLifecycleState.resumed);
  });

  test('全屏应用在前台时不允许，退出后恢复', () {
    var fullscreen = false;
    WallpaperGate.probeOverride = () => fullscreen;
    WallpaperGate.start();
    // 真实环境里消费方(视频会话、WebView 挂起器)总在壳层 start 之前就注册了。
    WallpaperGate.ensure();
    expect(WallpaperGate.allowed.value, isTrue);

    fullscreen = true;
    WallpaperGate.pollNow();
    expect(WallpaperGate.allowed.value, isFalse, reason: '全屏应用盖住了壁纸');

    fullscreen = false;
    WallpaperGate.pollNow();
    expect(WallpaperGate.allowed.value, isTrue);
  });

  test('窗口隐藏时不允许，回来时立即重新探测而不是沿用旧答案', () {
    var fullscreen = false;
    WallpaperGate.probeOverride = () => fullscreen;
    WallpaperGate.start();
    WallpaperGate.ensure();
    expect(WallpaperGate.allowed.value, isTrue);

    AppActivity.update(AppLifecycleState.hidden);
    expect(WallpaperGate.allowed.value, isFalse);

    // 最小化的这几秒里完全可能已经有一个全屏应用起来了;回到可见时
    // 要重新问一次,而不是相信隐藏前的旧答案。
    fullscreen = true;
    AppActivity.update(AppLifecycleState.resumed);
    expect(WallpaperGate.allowed.value, isFalse);

    fullscreen = false;
    WallpaperGate.pollNow();
    expect(WallpaperGate.allowed.value, isTrue);
  });

  test('应用自己的浮层盖住窗口时不允许，收起即恢复', () {
    WallpaperGate.probeOverride = () => false;
    WallpaperGate.start();
    WallpaperGate.ensure();
    expect(WallpaperGate.allowed.value, isTrue);

    // 设置页画满整个客户区：窗口状态没变，但壁纸已经没人看得见了。
    WallpaperGate.occlude(true);
    expect(WallpaperGate.allowed.value, isFalse);

    // 探测照旧每两秒跑一次，它说的话不能把浮层的结论顶回去。
    WallpaperGate.pollNow();
    expect(WallpaperGate.allowed.value, isFalse);

    WallpaperGate.occlude(false);
    expect(WallpaperGate.allowed.value, isTrue);
  });
}
