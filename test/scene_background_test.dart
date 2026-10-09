import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/state/live_surfaces.dart';
import 'package:xgame_desktop/state/wallpaper_gate.dart';
import 'package:xgame_desktop/state/wallpaper_server.dart';
import 'package:xgame_desktop/ui/scene_background.dart';

/// Stands in for the real browser, copying the Windows plugin's habit of
/// building its native view from the creation parameters handed over once —
/// afterwards a rebuild changes nothing, so a stale page can only be mistaken
/// for a fresh one if the URL itself goes stale.
class _FakeWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
          PlatformInAppWebViewWidgetCreationParams params) =>
      _FakeWebView(params);
}

class _FakeWebView extends PlatformInAppWebViewWidget {
  _FakeWebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      _BornPage(url: params.initialUrlRequest?.url.toString() ?? '');

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}

class _BornPage extends StatefulWidget {
  const _BornPage({required this.url});

  final String url;

  @override
  State<_BornPage> createState() => _BornPageState();
}

class _BornPageState extends State<_BornPage> {
  /// Captured once, like the native view's own URL.
  late final String _url = widget.url;

  @override
  Widget build(BuildContext context) => Text('page:$_url');
}

void main() {
  setUpAll(() => InAppWebViewPlatform.instance = _FakeWebViewPlatform());

  // The live background ensures() the wallpaper gate now; take it back down
  // after each test so nothing of it leaks into the next one.
  tearDown(() {
    WallpaperGate.stop();
    WallpaperGate.probeOverride = null;
  });

  Future<String?> hosted(String pkgPath) async =>
      'http://127.0.0.1:1/scene/${Uri.encodeComponent(pkgPath)}/';

  testWidgets('换一个场景壁纸就是换一个渲染页，旧场景不会留在那', (tester) async {
    LiveSurfaces.scene = true;
    SceneBackground.urlResolver = hosted;
    addTearDown(() {
      LiveSurfaces.scene = false;
      SceneBackground.urlResolver = WallpaperServer.scenePageUrl;
    });

    var pkg = r'E:\workshop\100\scene.pkg';
    late StateSetter swap;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        swap = setState;
        return SceneBackground(pkgPath: pkg, fit: BoxFit.cover);
      }),
    ));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(pkg)}/?fit=cover&fps=30'),
        findsOneWidget);

    // The heart of the regression: the widget keeps its state across the
    // switch (same type, same position, no key), so only didUpdateWidget can
    // point it at the new package.
    swap(() => pkg = r'E:\workshop\200\scene.pkg');
    await tester.pumpAndSettle();
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(pkg)}/?fit=cover&fps=30'),
        findsOneWidget);
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(r'E:\workshop\100\scene.pkg')}/?fit=cover&fps=30'),
        findsNothing);
  });

  testWidgets('填充方式变了也换页：fit 走在 URL 上，键一变浏览器就重建', (tester) async {
    LiveSurfaces.scene = true;
    SceneBackground.urlResolver = hosted;
    addTearDown(() {
      LiveSurfaces.scene = false;
      SceneBackground.urlResolver = WallpaperServer.scenePageUrl;
    });

    const pkg = r'E:\workshop\100\scene.pkg';
    var fit = BoxFit.cover;
    late StateSetter swap;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        swap = setState;
        return SceneBackground(pkgPath: pkg, fit: fit);
      }),
    ));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(pkg)}/?fit=cover&fps=30'),
        findsOneWidget);

    swap(() => fit = BoxFit.contain);
    await tester.pumpAndSettle();
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(pkg)}/?fit=contain&fps=30'),
        findsOneWidget);
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(pkg)}/?fit=cover&fps=30'),
        findsNothing);
  });

  testWidgets('帧率跟填充一样走在 URL 上，换帧率就是换一页', (tester) async {
    LiveSurfaces.scene = true;
    SceneBackground.urlResolver = hosted;
    addTearDown(() {
      LiveSurfaces.scene = false;
      SceneBackground.urlResolver = WallpaperServer.scenePageUrl;
    });

    const pkg = r'E:\workshop\100\scene.pkg';
    var fps = 30;
    late StateSetter swap;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        swap = setState;
        return SceneBackground(pkgPath: pkg, fit: BoxFit.cover, fps: fps);
      }),
    ));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(pkg)}/?fit=cover&fps=30'),
        findsOneWidget);

    swap(() => fps = 60);
    await tester.pumpAndSettle();
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(pkg)}/?fit=cover&fps=60'),
        findsOneWidget);
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(pkg)}/?fit=cover&fps=30'),
        findsNothing);
  });

  testWidgets('先发起的渲染页后返回，也不会把旧场景顶回来', (tester) async {
    LiveSurfaces.scene = true;
    final pending = <String, Completer<String?>>{};
    SceneBackground.urlResolver = (pkgPath) {
      final key = Uri.encodeComponent(pkgPath);
      return pending.putIfAbsent(key, Completer<String?>.new).future;
    };
    addTearDown(() {
      LiveSurfaces.scene = false;
      SceneBackground.urlResolver = WallpaperServer.scenePageUrl;
    });

    const first = r'E:\workshop\100\scene.pkg';
    const second = r'E:\workshop\200\scene.pkg';
    var pkg = first;
    late StateSetter swap;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        swap = setState;
        return SceneBackground(pkgPath: pkg, fit: BoxFit.cover);
      }),
    ));

    // Switch before the first page resolves: two _starts are now in flight
    // (the pump is what runs didUpdateWidget).
    swap(() => pkg = second);
    await tester.pump();
    pending[Uri.encodeComponent(second)]!.complete(hosted(second));
    await tester.pumpAndSettle();
    final newPage =
        'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(second)}/?fit=cover&fps=30';
    expect(find.text(newPage), findsOneWidget);

    // The stale answer lands last; it must be dropped, not applied.
    pending[Uri.encodeComponent(first)]!.complete(hosted(first));
    await tester.pumpAndSettle();
    expect(find.text(newPage), findsOneWidget);
    expect(
        find.text(
            'page:http://127.0.0.1:1/scene/${Uri.encodeComponent(first)}/?fit=cover&fps=30'),
        findsNothing);
  });
}
