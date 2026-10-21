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
    // A first start: random face, no account, never joined or hosted; the
    // app is installed.
    expect(find.text('Get ready (4 to go)'), findsOneWidget);
    expect(find.text('About'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Draw'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);

    // Tapping the logo again does not stack a second About page.
    await tester.tap(find.byKey(const ValueKey('about-button')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);

    state.setFace(List.of(state.face));
    await tester.pumpAndSettle();
    expect(state.drewFace, isTrue);
    expect(find.text('Get ready (3 to go)'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Draw'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('everything done hides the checklist', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'joined_room': true, 'hosted_own_room': true});
    final prefs = await SharedPreferences.getInstance();
    final state = AppState(prefs);
    state.setFace(List.of(state.face));
    await tester.pumpWidget(MaterialApp(home: AboutScreen(state: state)));
    // Signing in is still open.
    expect(find.text('Get ready (1 to go)'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('about-github')), 200);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('no sidebar tab is current while About is open', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = AppState(prefs);
    await tester.pumpWidget(GameNightApp(state: state));
    bool selected(String key) =>
        tester
            .getSemantics(find.byKey(ValueKey(key)))
            .flagsCollection
            .isSelected
            .toBoolOrNull() ==
        true;
    expect(selected('desktop-tab-0'), isTrue);
    await tester.tap(find.byKey(const ValueKey('about-button')));
    await tester.pumpAndSettle();
    expect(selected('desktop-tab-0'), isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(selected('desktop-tab-0'), isTrue);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
