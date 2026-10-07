import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('first launch opens on joining a GameNight', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance());
    await tester.pumpWidget(GameNightApp(state: state));
    expect(find.text('Scan lobby QR'), findsOneWidget);
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();
    expect(find.text('Draw your face'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    state.dispose();
  });
}
