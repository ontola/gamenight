import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/catalog.dart';
import 'package:gamenight/screens/catalog_view.dart';
import 'package:gamenight/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hosted_room_test.dart' show roomFixture;

final games = [
  {
    'id': 'a',
    'title': 'Moon Cards',
    'developer': 'Ada',
    'added': 300,
    'updated': 300,
  },
  {
    'id': 'b',
    'title': 'Rocket Rally',
    'developer': 'Bo',
    'added': 100,
    'updated': 500,
  },
  {
    'id': 'c',
    'title': 'Forest Friends',
    'developer': 'Ada',
    'added': 200,
    'updated': 200,
  },
];

List<String> shown(WidgetTester tester) => [
      for (final card in tester.widgetList<GameCard>(find.byType(GameCard)))
        card.game.id
    ];

void main() {
  test('joining a room queues the Want to play list once', () async {
    SharedPreferences.setMockInitialValues(
        {'cloud_token': 'test-only', 'hosted_room': true});
    final queued = <String>[];
    final cloud = CloudApi(client: MockClient((request) async {
      switch (request.url.path) {
        case '/v1/me/want-to-play':
          return http.Response(jsonEncode(['neon-siege', 'ballkickers']), 200);
        case '/v1/me/last-played':
          return http.Response(jsonEncode({'pocket-aces': 1700000000}), 200);
        case '/v1/rooms/status':
          return http.Response(jsonEncode(roomFixture()), 200);
        case '/v1/rooms/next':
          queued.add((jsonDecode(request.body) as Map)['game'] as String);
          return http.Response('{}', 200);
      }
      return http.Response('', 204);
    }));
    final state = AppState(await SharedPreferences.getInstance(), cloud: cloud);
    addTearDown(state.dispose);
    await state.loadPlayLists();
    expect(state.lastPlayed, {'pocket-aces': 1700000000});
    await state.refreshHostedRoom();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    // An online room takes one pick: the oldest wish.
    expect(queued, ['neon-siege']);
    await state.refreshHostedRoom();
    await Future<void>.delayed(Duration.zero);
    expect(queued, ['neon-siege']);
  });

  testWidgets('sort, Want to play filter and developer pages', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cloud_token': 'test-only'});
    final saved = <Map>[];
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/v1/catalog':
          return http.Response(jsonEncode(games), 200);
        case '/v1/game-ratings':
          return http.Response(
              jsonEncode({
                'a': {'up': 1, 'down': 1},
                'c': {'up': 3, 'down': 0}
              }),
              200);
        case '/v1/me/want-to-play':
          if (request.method == 'PUT') {
            saved.add(jsonDecode(request.body) as Map);
            return http.Response('', 204);
          }
          return http.Response(jsonEncode(['c']), 200);
        case '/v1/me/last-played':
          return http.Response(jsonEncode({}), 200);
      }
      return http.Response('{}', 200);
    });
    final cloud = CloudApi(client: client);
    Catalog.instance = Catalog(client: client);
    final state = AppState(await SharedPreferences.getInstance(), cloud: cloud);
    await state.loadPlayLists();
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: Scaffold(
            body: ListenableBuilder(
                listenable: state,
                builder: (context, _) => SingleChildScrollView(
                    child: CatalogSection(cloud: cloud, state: state))))));
    await tester.pumpAndSettle();
    expect(shown(tester), ['a', 'b', 'c']);

    Future<void> sortBy(String label) async {
      await tester.tap(find.byKey(const ValueKey('catalog-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await sortBy('A to Z');
    expect(shown(tester), ['c', 'a', 'b']);
    await sortBy('Newest');
    expect(shown(tester), ['a', 'c', 'b']);
    await sortBy('Recently updated');
    expect(shown(tester), ['b', 'a', 'c']);
    await sortBy('Most liked');
    expect(shown(tester), ['c', 'a', 'b']);

    await tester.tap(find.byKey(const ValueKey('want-to-play')));
    await tester.pumpAndSettle();
    expect(shown(tester), ['c']);
    await tester.tap(find.byKey(const ValueKey('want-to-play')));
    await tester.pumpAndSettle();

    // The game page saves a wish and links to its developer's games.
    await tester.tap(find.byKey(const ValueKey('a')));
    await tester.pumpAndSettle();
    expect(
        find.text('Join a room to put this game in the queue.'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Want to play'));
    await tester.pumpAndSettle();
    expect(saved.single, {'game': 'a', 'want': true});
    expect(state.wantToPlay, ['c', 'a']);
    expect(find.text('On your Want to play list'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('developer')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Ada'), findsOneWidget);
    expect(find.text('2 games by Ada'), findsOneWidget);
    expect(shown(tester), ['a', 'c']);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
