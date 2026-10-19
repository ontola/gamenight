import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/catalog.dart';
import 'package:gamenight/screens/catalog_view.dart';
import 'package:gamenight/screens/catalog_filters.dart';
import 'package:gamenight/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final games = [
  {
    'id': 'a',
    'title': 'Moon Cards',
    'tags': ['cards', 'party']
  },
  {
    'id': 'b',
    'title': 'Rocket Rally',
    'tags': ['racing', 'party']
  },
  {
    'id': 'c',
    'title': 'Forest Friends',
    'tags': ['co-op']
  },
];

void main() {
  testWidgets('liked and unplayed intersect; tags use OR; clear restores all',
      (tester) async {
    Catalog.instance = Catalog(
        client: MockClient((_) async => http.Response(jsonEncode(games), 200)));
    final cloud = CloudApi(
        token: 'test',
        client: MockClient((r) async => http.Response(
            jsonEncode(r.url.path.endsWith('game-ratings')
                ? {'a': 1, 'b': -1, 'c': 1}
                : {
                    'window_days': 90,
                    'games': [
                      {'game': 'a', 'active_ms': 2000, 'rounds_reported': 0},
                      {'game': 'c', 'active_ms': 0, 'rounds_reported': 0}
                    ]
                  }),
            200)));
    addTearDown(cloud.close);
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: Scaffold(
            body: SingleChildScrollView(child: CatalogSection(cloud: cloud)))));
    await tester.pumpAndSettle();
    expect(find.text('Games'), findsNothing);
    await tester.tap(find.text('Filter'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Liked'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Not played'));
    await tester.pumpAndSettle();
    expect(find.text('Show 1 game'), findsOneWidget);
    await tester.tap(find.text('Show 1 game'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widgetList<GameCard>(find.byType(GameCard))
            .map((c) => c.game.id),
        ['c']);
    await tester.tap(find.text('Filter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'cards'));
    await tester.tap(find.widgetWithText(FilterChip, 'racing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show 2 games'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widgetList<GameCard>(find.byType(GameCard))
            .map((c) => c.game.id),
        ['a', 'b']);
    await tester.tap(find.byType(GameCard).first);
    await tester.pumpAndSettle();
    expect(find.text('Give feedback'), findsNothing);
    await tester.ensureVisible(find.widgetWithText(ActionChip, 'party').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'party').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'party'), findsOneWidget);
    expect(
        tester
            .widgetList<GameCard>(find.byType(GameCard))
            .map((c) => c.game.id),
        ['a', 'b']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('games you develop get Manage game, others do not',
      (tester) async {
    Catalog.instance = Catalog(
        client: MockClient((_) async => http.Response(jsonEncode(games), 200)));
    final cloud = CloudApi(
        token: 'test',
        client: MockClient((r) async => r.url.path == '/v1/developer/games'
            ? http.Response(
                jsonEncode({
                  'games': [
                    {'id': 'b', 'metadata': {}, 'approved': true},
                    {
                      'id': 'z',
                      'metadata': {'title': 'Secret Prototype'},
                      'approved': false
                    }
                  ]
                }),
                200)
            : http.Response('{}', 200)));
    addTearDown(cloud.close);
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: Scaffold(
            body: SingleChildScrollView(child: CatalogSection(cloud: cloud)))));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byWidgetPredicate((w) => w is GameCard && w.game.id == 'b'));
    await tester.pumpAndSettle();
    expect(find.text('Manage game'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester
        .tap(find.byWidgetPredicate((w) => w is GameCard && w.game.id == 'a'));
    await tester.pumpAndSettle();
    expect(find.text('Manage game'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Unreviewed games only show under My games, next to the listed ones.
    List<String> shown() => tester
        .widgetList<GameCard>(find.byType(GameCard))
        .map((c) => c.game.id)
        .toList();
    expect(shown(), isNot(contains('z')));
    await tester.tap(find.byKey(const ValueKey('my-games')));
    await tester.pumpAndSettle();
    expect(shown()..sort(), ['b', 'z']);
    await tester
        .tap(find.byWidgetPredicate((w) => w is GameCard && w.game.id == 'z'));
    await tester.pumpAndSettle();
    expect(find.text('Manage game'), findsOneWidget);
    expect(find.textContaining('Join a room to playtest'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping a tag never focuses the search field', (tester) async {
    Catalog.instance = Catalog(
        client: MockClient((_) async => http.Response(jsonEncode(games), 200)));
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: const Scaffold(
            body: SingleChildScrollView(child: CatalogSection()))));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('catalog-search'));
    bool searchFocused() => tester
        .widget<EditableText>(
            find.descendant(of: search, matching: find.byType(EditableText)))
        .focusNode
        .hasFocus;
    await tester.enterText(search, 'moon');
    await tester.pumpAndSettle();
    expect(searchFocused(), isTrue);
    await tester.tap(find.byType(GameCard).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ActionChip, 'party').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'party').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'party'), findsOneWidget);
    expect(searchFocused(), isFalse);
    expect(find.text('moon'), findsNothing);

    await tester.tap(find.text('Filter'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'cards'));
    await tester.tap(find.text('Show 2 games'));
    await tester.pumpAndSettle();
    expect(searchFocused(), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'failed personal data never becomes an empty history; tags still work',
      (tester) async {
    final cloud = CloudApi(
        token: 'test', client: MockClient((_) async => http.Response('', 503)));
    addTearDown(cloud.close);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CatalogFilters(
                filter: const CatalogFilter(unplayed: true),
                games: parseCatalog(games),
                cloud: cloud))));
    await tester.pumpAndSettle();
    expect(find.text('Could not load your likes and play history.'),
        findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'cards'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });

  testWidgets('signed out can filter tags but no pretend personal history',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CatalogFilters(
                filter: const CatalogFilter(), games: parseCatalog(games)))));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'Liked'))
            .onSelected,
        isNull);
    expect(find.text('Sign in to filter by your likes and play history.'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'co-op'));
    await tester.pumpAndSettle();
    expect(find.text('Show 1 game'), findsOneWidget);
  });

  test('search matches every word; player count fits min and max', () {
    final list = parseCatalog([
      {
        'id': 'a',
        'title': 'Moon Cards',
        'tagline': 'Bluff with friends',
        'players': {'min': 2, 'max': 4}
      },
      {
        'id': 'b',
        'title': 'Rocket Rally',
        'players': {'min': 1, 'max': 8}
      },
      {'id': 'c', 'title': 'Forest Friends'},
    ]);
    ids(CatalogFilter f) => [
          for (final g in list)
            if (f.matches(g)) g.id
        ];
    expect(ids(const CatalogFilter(query: 'moon BLUFF')), ['a']);
    expect(ids(const CatalogFilter(query: 'friends')), ['a', 'c']);
    expect(ids(const CatalogFilter(players: 6)), ['b', 'c']);
    expect(ids(const CatalogFilter(players: 2, query: 'r')), ['a', 'b', 'c']);
    expect(
        const CatalogFilter(players: 3).copyWith(players: () => null).players,
        isNull);
  });
}
