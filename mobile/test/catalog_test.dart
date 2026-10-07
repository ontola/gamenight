import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/catalog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A trimmed sample of `GET /v1/catalog`.
Object fixture() => jsonDecode(File('test/fixtures/catalog.json').readAsStringSync());

void main() {
  test('reads games, their covers and player counts from the catalog', () {
    final games = parseCatalog(fixture());
    expect(games.map((g) => g.id), ['ballkickers', 'growing-guns', 'pinpals'],
        reason: 'the lobby and entries without an id are not games to pick');

    final ball = games[0];
    expect(ball.title, 'Ballkickers');
    expect(ball.tagline, startsWith('Chaotic party football'));
    expect(ball.players, '1–6 players');
    expect(ball.bestPlayers, 4);
    expect(ball.coverBytes, isNotNull, reason: 'data: covers are decoded once');
    expect(ball.coverBytes!.sublist(1, 4), utf8.encode('PNG'));
    expect(ball.coverUrl, isNull);
    expect(ball.color, const Color(0xFFFF7547));
    expect(ball.page, Uri.parse('https://gamenight.ontola.io/games/ballkickers'));

    final guns = games[1];
    expect(guns.coverBytes, isNull);
    expect(guns.coverUrl, isNull);
    expect(guns.color, const Color(0xFFFFB454), reason: 'no cover: a tile in its colour');

    final pinpals = games[2];
    expect(pinpals.coverUrl, Uri.parse('https://gamenight.ontola.io/media/pinpals/cover.png'));
    expect(pinpals.players, '2 players');
    expect(pinpals.color, isNull);
  });

  test('reads the same videos, screenshots and facts as the website', () {
    final games = parseCatalog(fixture());
    final pinpals = games[2];
    expect(pinpals.media.map((m) => m.kind),
        [MediaKind.video, MediaKind.trailer, MediaKind.image],
        reason: 'looping preview first, images last, insecure videos dropped');
    expect(pinpals.media[0].preview, isTrue);
    expect(pinpals.media[0].poster!.url.toString(), 'https://gamenight.ontola.io/media/pinpals/preview.jpg');
    expect(pinpals.platformLabel, 'Windows · Linux');
    expect(pinpals.links.keys, ['homepage'], reason: 'only web links');
    expect(pinpals.mediaSource, Uri.parse('https://example.org/pinpals'));

    final ball = games[0];
    expect(ball.media.single.image!.url, Uri.parse('https://gamenight.ontola.io/game-images/ballkickers.png'),
        reason: 'the screenshot is a slide');
    expect(ball.matchMinutes, 2);
    expect(games[1].media, isEmpty, reason: 'nothing to show: the colour tile stands in');
    expect(ball.similar(games).map((g) => g.id), ['growing-guns'], reason: 'they share tags');
  });

  test('tolerates odd entries', () {
    final games = parseCatalog([
      {
        'id': 'a',
        'title': 'A',
        'players': {'max': 1},
        'cover': 'data:,not-base64',
        'color': 'red'
      },
      {'id': 'b', 'title': 'B', 'cover': '/media/b.png', 'players': 'many'},
      'nonsense',
    ]);
    expect(games.map((g) => g.id), ['a', 'b']);
    expect(games[0].players, '1 player');
    expect(games[0].color, isNull);
    expect(games[1].coverUrl, Uri.parse('https://gamenight.ontola.io/media/b.png'));
    expect(games[1].players, '');
    expect(() => parseCatalog({'games': []}), throwsFormatException);
  });

  test('loads the catalog once and retries after a failure', () async {
    var calls = 0;
    var fail = true;
    final catalog = Catalog(
      client: MockClient((request) async {
        calls++;
        expect(request.url, Uri.parse('https://gamenight.ontola.io/v1/catalog'));
        if (fail) return http.Response('down', 503);
        return http.Response.bytes(utf8.encode(jsonEncode(fixture())), 200);
      }),
    );
    await expectLater(catalog.games(), throwsA(isA<CatalogError>()));
    fail = false;
    expect((await catalog.games()).length, 3);
    expect((await catalog.games()).length, 3);
    expect(calls, 2);
  });
}
