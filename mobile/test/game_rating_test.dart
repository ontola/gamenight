import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/theme.dart';
import 'package:gamenight/widgets/game_rating.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<Map<String, dynamic>> votes;
  CloudApi cloud({String? token}) => CloudApi(
      token: token,
      client: MockClient((r) async {
        switch ('${r.method} ${r.url.path}') {
          case 'GET /v1/game-ratings':
            return http.Response(
                jsonEncode({
                  'played': {'up': 3, 'down': 1}
                }),
                200);
          case 'GET /v1/me/game-ratings':
            return http.Response('{}', 200);
          case 'GET /v1/me/played-games':
            return http.Response(jsonEncode(['played']), 200);
          case 'PUT /v1/me/game-ratings':
            votes.add(jsonDecode(r.body) as Map<String, dynamic>);
            return http.Response('', 204);
        }
        return http.Response('', 404);
      }));
  setUp(() => votes = []);

  Future<void> show(WidgetTester tester, String game, CloudApi api) async {
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: Scaffold(body: GameRating(game: game, cloud: api))));
    await tester.pumpAndSettle();
  }

  testWidgets('everyone sees the like percentage; signing in is asked',
      (tester) async {
    await show(tester, 'played', cloud());
    expect(find.text('75% like it · 4 votes'), findsOneWidget);
    expect(find.text('Sign in to vote.'), findsOneWidget);
    await tester.tap(find.byTooltip('Thumbs up'));
    expect(votes, isEmpty);
  });

  testWidgets('a game you played takes your vote', (tester) async {
    await show(tester, 'played', cloud(token: 'test'));
    await tester.tap(find.byTooltip('Thumbs up'));
    await tester.pumpAndSettle();
    expect(votes, [
      {'game': 'played', 'rating': 1}
    ]);
    expect(find.text('80% like it · 5 votes'), findsOneWidget);
  });

  testWidgets('a game you never played cannot be voted on', (tester) async {
    await show(tester, 'other', cloud(token: 'test'));
    expect(find.text('No votes yet'), findsOneWidget);
    expect(find.text('Play this game to vote on it.'), findsOneWidget);
    await tester.tap(find.byTooltip('Thumbs down'));
    expect(votes, isEmpty);
  });
}
