import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/core/theme.dart';
import 'package:xgame_desktop/ui/boot_splash.dart';
import 'package:xgame_desktop/ui/brand_mark.dart';

/// The opening screen on its own: no catalog, no shell. What is loading comes
/// in as plain values, so the whole sequence — assembly, hold, split — is
/// driven here by hand.
void main() {
  Future<void> pumpSplash(
    WidgetTester tester, {
    required bool ready,
    bool skipped = false,
    bool disableAnimations = false,
    double progress = 0.4,
    String label = '正在读取应用图标 12/30',
    VoidCallback? onSkip,
    VoidCallback? onRevealed,
    VoidCallback? onFinished,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(appPalettes.first),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: BootSplash(
            progress: progress,
            label: label,
            ready: ready,
            skipped: skipped,
            onSkip: onSkip,
            onRevealed: onRevealed,
            onFinished: onFinished,
          ),
        ),
      ),
    );
  }

  testWidgets('the mark draws itself, the line reports the load', (tester) async {
    await pumpSplash(tester, ready: false);

    // The load's own line, and an icon that has not started assembling.
    expect(find.text('正在读取应用图标 12/30'), findsOneWidget);
    expect(tester.widget<BrandMark>(find.byType(BrandMark)).reveal, 0);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1050));
    expect(tester.widget<BrandMark>(find.byType(BrandMark)).reveal, 1,
        reason: '一整段动画之后，图标已经拼好');

    // Not ready means not leaving, however long the load takes.
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(BootSplash), findsOneWidget);
    expect(find.byType(ClipPath), findsNothing, reason: '没装完就不该裂开');
  });

  testWidgets('ready holds a beat, then the field splits and flies', (tester) async {
    var revealed = 0;
    var finished = 0;
    await pumpSplash(
      tester,
      ready: true,
      progress: 1,
      label: '就绪',
      onRevealed: () => revealed++,
      onFinished: () => finished++,
    );

    // The hold is part of the sequence: the load being done does not cut the
    // assembly short.
    await tester.pump(const Duration(milliseconds: 600));
    expect(revealed, 0);
    expect(find.byType(ClipPath), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    expect(revealed, 1, reason: '拼好之后才开始送客');
    expect(finished, 0);
    expect(find.byType(ClipPath), findsNWidgets(4),
        reason: '四块，各奔一个角');

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(finished, 1);
  });

  testWidgets('a press anywhere is the user saying "enough"', (tester) async {
    var skips = 0;
    await pumpSplash(tester, ready: false, onSkip: () => skips++);

    await tester.tapAt(tester.getCenter(find.byType(BootSplash)));
    await tester.pump();
    expect(skips, 1);
  });

  testWidgets('a skip is honoured without waiting for the load', (tester) async {
    var revealed = 0;
    await pumpSplash(
      tester,
      ready: false,
      skipped: true,
      onRevealed: () => revealed++,
    );

    await tester.pump(const Duration(milliseconds: 1200));
    expect(revealed, 1);
  });

  testWidgets('with motion reduced it does not animate, and does not split',
      (tester) async {
    var revealed = 0;
    var finished = 0;
    await pumpSplash(
      tester,
      ready: true,
      disableAnimations: true,
      onRevealed: () => revealed++,
      onFinished: () => finished++,
    );
    await tester.pump();

    // The finished icon from the first frame, no pieces, and the shell is
    // handed the window straight away.
    expect(tester.widget<BrandMark>(find.byType(BrandMark)).reveal, 1);
    expect(find.byType(ClipPath), findsNothing);
    expect(revealed, 1);
    expect(finished, 1);
  });
}
