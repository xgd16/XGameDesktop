import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/ui/widgets.dart';

const _hero = TextStyle(fontFamily: 'Rajdhani', fontSize: 46, height: 1.0);

/// Regression: the animated path renders every intermediate frame through a
/// builder, and an unstyled Text there falls back to the default body face —
/// which detaches the number from the styled '%' beside it (the panel showed
/// a small default-font value under a large floating percent sign).
void main() {
  Future<void> pump(WidgetTester tester, {required bool disableAnimations}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: const Scaffold(body: FlipValue(13, style: _hero)),
        ),
      ),
    );
  }

  Text valueText(WidgetTester tester) =>
      tester.widget<Text>(find.textContaining(RegExp(r'^\d+$')));

  testWidgets('eased frames keep the telemetry style', (tester) async {
    await pump(tester, disableAnimations: false);

    // First builder frame (counts up from zero) — the buggy path.
    await tester.pump();
    expect(valueText(tester).style?.fontSize, 46);
    expect(valueText(tester).style?.fontFamily, 'Rajdhani');

    // Settled readout.
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('13'), findsOneWidget);
    expect(valueText(tester).style?.fontSize, 46);
  });

  testWidgets('reduced motion keeps the telemetry style', (tester) async {
    await pump(tester, disableAnimations: true);
    await tester.pump();

    expect(find.text('13'), findsOneWidget);
    expect(valueText(tester).style?.fontSize, 46);
    expect(valueText(tester).style?.fontFamily, 'Rajdhani');
  });
}
