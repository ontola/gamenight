import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/main.dart';
import 'package:gamenight/screens/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('first launch opens on joining a GameNight', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance());
    await tester.pumpWidget(GameNightApp(state: state));
    expect(find.text('Scan the QR on the TV'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing, reason: 'signing in lives on the You tab');
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();
    expect(find.text('Draw your face'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    await tester.scrollUntilVisible(find.text('Sign in'), 200,
        scrollable: find
            .descendant(of: find.byType(PlayerScreen), matching: find.byType(Scrollable))
            .first);
    expect(find.text('Sign in'), findsOneWidget);
    state.dispose();
  });
}
