import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/main.dart';
import 'package:gamenight/screens/about_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the logo opens About with the open todos', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = AppState(prefs);
    await tester.pumpWidget(GameNightApp(state: state));
    await tester.tap(find.byKey(const ValueKey('about-button')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
    // A first start has a random face and no account; the app is installed.
    expect(find.text('Get ready (2 to go)'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Draw'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);

    // Tapping the logo again does not stack a second About page.
    await tester.tap(find.byKey(const ValueKey('about-button')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);

    state.setFace(List.of(state.face));
    await tester.pumpAndSettle();
    expect(state.drewFace, isTrue);
    expect(find.text('Get ready (1 to go)'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Draw'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
