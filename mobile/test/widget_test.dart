import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/api.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/main.dart';
import 'package:gamenight/reports.dart';
import 'package:gamenight/screens/feedback_screen.dart';
import 'package:gamenight/screens/face_editor_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('branding and feedback stay available on a pushed page',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = AppState(prefs);
    await tester
        .pumpWidget(GameNightApp(state: state, reports: ReportService(prefs)));
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(body: Center(child: Text('Game details'))))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-brand')), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Feedback'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('app-brand')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
      'desktop shell survives detail, face, feedback and window resizing',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = AppState(prefs);
    await tester
        .pumpWidget(GameNightApp(state: state, reports: ReportService(prefs)));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
    for (final label in [
      'Developer portal',
      'Documentation',
      'Host a room',
      'Assistant',
      'Feedback'
    ]) {
      expect(find.descendant(of: sidebar, matching: find.text(label)),
          findsOneWidget);
    }
    expect(find.byIcon(Icons.menu), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    var builds = 0;
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) {
      builds++;
      return const Scaffold(body: Center(child: Text('Detail route')));
    })));
    await tester.pumpAndSettle();
    expect(sidebar.hitTestable(), findsOneWidget);
    expect(find.text('Detail route'), findsOneWidget);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.text('Detail route'), findsOneWidget);
    expect(sidebar, findsNothing);
    tester.view.physicalSize = const Size(1280, 900);
    await tester.pumpAndSettle();
    expect(sidebar.hitTestable(), findsOneWidget);
    expect(builds, 1, reason: 'Resizing must keep the existing route');
    await tester.tap(find.byKey(const ValueKey('desktop-tab-2')));
    await tester.pumpAndSettle();
    expect(find.text('Detail route'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Edit face'));
    await tester.pumpAndSettle();
    expect(find.byType(FaceEditorScreen), findsOneWidget);
    expect(sidebar.hitTestable(), findsOneWidget);
    await tester
        .tap(find.descendant(of: sidebar, matching: find.text('Feedback')));
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackScreen), findsOneWidget);
    expect(sidebar.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('first launch opens on joining a GameNight', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance());
    await tester.pumpWidget(GameNightApp(state: state));
    expect(find.text('Scan the QR on the TV'), findsOneWidget);
    expect(find.text('Sign in with email'), findsNothing,
        reason: 'signing in lives on the You tab');
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('Sign in with email').hitTestable(), findsOneWidget,
        reason: 'sign in is the first thing on the You tab');
    state.dispose();
  });

  testWidgets(
      'a sign-in link from the email opens the app and says what happened',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance());
    final links = StreamController<Uri>();
    addTearDown(links.close);
    await tester.pumpWidget(GameNightApp(state: state, links: links.stream));
    links.add(Uri.parse('https://gamenight.ontola.io/auth/app#code=12345678'));
    await tester.pumpAndSettle();
    expect(find.textContaining('belongs to another phone or browser'),
        findsOneWidget,
        reason: 'no code was asked for on this phone');
    links.add(Uri.parse('https://example.org/other'));
    await tester.pumpAndSettle();
    state.dispose();
  });

  testWidgets('an unreachable GameNight shows a warning, not a green check',
      (tester) async {
    SharedPreferences.setMockInitialValues({'host': 'http://192.168.1.5:3000'});
    final state = AppState(await SharedPreferences.getInstance());
    state.session = const SessionInfo(linked: true, playerId: 'p1', players: 1);
    state.sessionError =
        'GameNight is unreachable. Join the same Wi-Fi as the GameNight PC.';
    await tester.pumpWidget(GameNightApp(state: state));
    await tester.tap(find.widgetWithText(NavigationDestination, 'Room'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('unreachable'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    state.dispose();
  });
}
