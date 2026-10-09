import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/state/live_surfaces.dart';
import 'package:xgame_desktop/state/wallpaper_gate.dart';
import 'package:xgame_desktop/state/wallpaper_server.dart';
import 'package:xgame_desktop/ui/web_background.dart';

/// Stands in for the real browser. The Windows plugin builds its native view
/// from the creation parameters handed over once, at creation — afterwards the
/// widget can be rebuilt with anything and the page will not change. The fake
/// copies that behaviour on purpose: without it a rebuild would look like a
/// navigation and the test below would pass on broken code.
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

  testWidgets('换一个网页壁纸就是换一个页面，旧页面不会留在那', (tester) async {
    LiveSurfaces.web = true;
    WebBackground.urlResolver = (path) async =>
        'http://127.0.0.1:1/web/${Uri.encodeComponent(path)}';
    addTearDown(() {
      LiveSurfaces.web = false;
      WebBackground.urlResolver = WallpaperServer.webPageUrl;
    });

    final dir = Directory.systemTemp.createTempSync('xg_web_switch');
    addTearDown(() => dir.deleteSync(recursive: true));
    final first = '${dir.path}\\one\\index.html';
    final second = '${dir.path}\\two\\index.html';
    final firstUrl = await WebBackground.urlResolver(first);
    final secondUrl = await WebBackground.urlResolver(second);

    var path = first;
    late StateSetter swap;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        swap = setState;
        return WebBackground(path: path);
      }),
    ));
    await tester.pumpAndSettle();
    expect(find.text('page:$firstUrl'), findsOneWidget);

    swap(() => path = second);
    await tester.pumpAndSettle();

    expect(find.text('page:$secondUrl'), findsOneWidget);
    expect(find.text('page:$firstUrl'), findsNothing);
  });

  testWidgets('快速连点两个网页壁纸，先发起的后返回也不会把旧页面顶回来', (tester) async {
    LiveSurfaces.web = true;
    String hosted(String path) =>
        'http://127.0.0.1:1/web/${Uri.encodeComponent(path)}';
    final pending = <String, Completer<String?>>{};
    WebBackground.urlResolver = (path) {
      final key = Uri.encodeComponent(path);
      return pending.putIfAbsent(key, Completer<String?>.new).future;
    };
    addTearDown(() {
      LiveSurfaces.web = false;
      WebBackground.urlResolver = WallpaperServer.webPageUrl;
    });

    final dir = Directory.systemTemp.createTempSync('xg_web_race');
    addTearDown(() => dir.deleteSync(recursive: true));
    const first = r'E:\workshop\500\index.html';
    const second = r'E:\workshop\600\index.html';

    var path = first;
    late StateSetter swap;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        swap = setState;
        return WebBackground(path: path);
      }),
    ));

    // Switch before the first page resolves: two _starts are now in flight
    // (the pump is what runs didUpdateWidget).
    swap(() => path = second);
    await tester.pump();
    pending[Uri.encodeComponent(second)]!.complete(hosted(second));
    await tester.pumpAndSettle();
    final newPage = 'page:${hosted(second)}';
    expect(find.text(newPage), findsOneWidget);

    // The stale answer lands last; it must be dropped, not applied.
    pending[Uri.encodeComponent(first)]!.complete(hosted(first));
    await tester.pumpAndSettle();
    expect(find.text(newPage), findsOneWidget);
    expect(find.text('page:${hosted(first)}'), findsNothing);
  });
}
