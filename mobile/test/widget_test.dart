import 'dart:async';

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
    expect(find.text('Scan the QR on the TV'), findsOneWidget);
    expect(find.text('Sign in with email'), findsNothing, reason: 'signing in lives on the You tab');
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('Sign in with email').hitTestable(), findsOneWidget,
        reason: 'sign in is the first thing on the You tab');
    state.dispose();
  });

  testWidgets('a sign-in link from the email opens the app and says what happened', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance());
    final links = StreamController<Uri>();
    addTearDown(links.close);
    await tester.pumpWidget(GameNightApp(state: state, links: links.stream));
    links.add(Uri.parse('https://gamenight.ontola.io/auth/login#code=12345678'));
    await tester.pumpAndSettle();
    expect(find.textContaining('belongs to another phone or browser'), findsOneWidget,
        reason: 'no code was asked for on this phone');
    links.add(Uri.parse('https://example.org/other'));
    await tester.pumpAndSettle();
    state.dispose();
  });
}
