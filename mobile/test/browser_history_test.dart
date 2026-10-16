import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/navigation/browser_history.dart';

void main() {
  testWidgets(
      'browser history restores tabs and rebuilds disposed detail routes',
      (tester) async {
    final key = GlobalKey<NavigatorState>();
    final reports = <RouteInformation>[];
    final replacements = <bool>[];
    var fullscreen = false, backs = 0, builtDetails = 0;
    final history = BrowserNavigation(
        navigatorKey: key,
        fullscreen: () => fullscreen,
        setFullscreen: (value) => fullscreen = value,
        attach: false,
        back: () => backs++,
        report: (information, replace) async {
          reports.add(information);
          replacements.add(replace);
        });
    await tester.pumpWidget(MaterialApp(
        home: Navigator(
      key: key,
      observers: [history.observer],
      onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => ListenableBuilder(
              listenable: history,
              builder: (_, __) => Text('Tab ${history.tab}'))),
    )));
    await tester.pumpAndSettle();
    expect(reports, hasLength(1));
    expect(replacements.single, isTrue);
    final room = reports.last;
    history.selectTab(1);
    await tester.pumpAndSettle();
    final games = reports.last;
    history.selectTab(1);
    await tester.pumpAndSettle();
    expect(reports, hasLength(2), reason: 'Repeated tab taps add no history');
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) {
      builtDetails++;
      return const Scaffold(body: Text('Game details'));
    }));
    await tester.pumpAndSettle();
    final detail = reports.last, beforeReplay = reports.length;
    expect(find.text('Game details'), findsOneWidget);
    await history.didPushRouteInformation(games);
    await tester.pumpAndSettle();
    expect(find.text('Tab 1'), findsOneWidget);
    expect(find.text('Game details'), findsNothing);
    await history.didPushRouteInformation(room);
    await tester.pumpAndSettle();
    expect(find.text('Tab 0'), findsOneWidget);
    await history.didPushRouteInformation(games);
    await history.didPushRouteInformation(detail);
    await tester.pumpAndSettle();
    expect(find.text('Game details'), findsOneWidget);
    expect(builtDetails, greaterThan(1),
        reason: 'Forward creates a fresh Route');
    expect(reports, hasLength(beforeReplay),
        reason: 'Replay must not push history');
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(backs, 1, reason: 'App Back traverses existing browser history');
    await history.didPushRouteInformation(games);
    await tester.pumpAndSettle();
    fullscreen = true;
    history.fullscreenChanged();
    await tester.pumpAndSettle();
    final full = reports.last;
    await history.didPushRouteInformation(games);
    await tester.pumpAndSettle();
    expect(fullscreen, isFalse);
    await history.didPushRouteInformation(full);
    await tester.pumpAndSettle();
    expect(fullscreen, isTrue);
    expect(full.uri.toString(), isNot(contains('token')));
    await tester.pumpWidget(const SizedBox());
    history.dispose();
  });

  testWidgets('history from a previous page load cannot resolve new route IDs',
      (tester) async {
    Future<
        (
          BrowserNavigation,
          GlobalKey<NavigatorState>,
          List<RouteInformation>
        )> mount() async {
      final key = GlobalKey<NavigatorState>();
      final reports = <RouteInformation>[];
      final history = BrowserNavigation(
          navigatorKey: key,
          fullscreen: () => false,
          setFullscreen: (_) {},
          attach: false,
          report: (value, _) async => reports.add(value));
      await tester.pumpWidget(MaterialApp(
          home: Navigator(
              key: key,
              observers: [history.observer],
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Root'))))));
      await tester.pumpAndSettle();
      return (history, key, reports);
    }

    final (old, oldKey, oldReports) = await mount();
    old.selectTab(1);
    oldKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Old game'))));
    await tester.pumpAndSettle();
    final stale = oldReports.last;
    expect((stale.state as Map)['instance'], matches(r'^[0-9a-f]{32}$'));
    expect((stale.state as Map)['routes'], [1]);
    await tester.pumpWidget(const SizedBox());
    old.dispose();

    final (fresh, freshKey, freshReports) = await mount();
    freshKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Unrelated new game'))));
    await tester.pumpAndSettle();
    expect((freshReports.last.state as Map)['routes'], [1]);
    expect((freshReports.last.state as Map)['instance'],
        isNot((stale.state as Map)['instance']));
    await fresh.didPushRouteInformation(stale);
    await tester.pumpAndSettle();
    expect(fresh.tab, 1);
    expect(find.text('Unrelated new game'), findsNothing);
    expect(find.text('Old game'), findsNothing);
    expect((freshReports.last.state as Map)['routes'], isEmpty);
    await tester.pumpWidget(const SizedBox());
    fresh.dispose();
  });

  testWidgets(
      'dialog Back dismisses first and stale Forward IDs fall back safely',
      (tester) async {
    final key = GlobalKey<NavigatorState>();
    final reports = <RouteInformation>[];
    final history = BrowserNavigation(
        navigatorKey: key,
        fullscreen: () => false,
        setFullscreen: (_) {},
        attach: false,
        report: (value, _) async => reports.add(value));
    await tester.pumpWidget(MaterialApp(
        home: Navigator(
      key: key,
      observers: [history.observer],
      onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Room'))),
    )));
    await tester.pumpAndSettle();
    final room = reports.last;
    showDialog<void>(
        context: key.currentContext!,
        useRootNavigator: false,
        builder: (_) => const AlertDialog(title: Text('Confirm')));
    await tester.pumpAndSettle();
    final dialog = reports.last;
    await history.didPushRouteInformation(room);
    await tester.pumpAndSettle();
    expect(find.text('Confirm'), findsNothing);
    await history.didPushRouteInformation(dialog);
    await tester.pumpAndSettle();
    expect(find.text('Confirm'), findsNothing,
        reason: 'Disposed dialogs are not reused');
    expect((reports.last.state as Map)['routes'], isEmpty);
    await history.didPushRouteInformation(
        RouteInformation(uri: Uri.parse('/games?screen=999'), state: {
      'gamenight_navigation': 1,
      'entry': 7,
      'tab': 1,
      'routes': [999]
    }));
    await tester.pumpAndSettle();
    expect(history.tab, 1);
    expect((reports.last.state as Map)['routes'], isEmpty);
    await tester.pumpWidget(const SizedBox());
    history.dispose();
  });
}
