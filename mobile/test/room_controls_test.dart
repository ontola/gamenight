import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/api.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/catalog.dart';
import 'package:gamenight/room_controls.dart';
import 'package:gamenight/screens/game_screen.dart';
import 'package:gamenight/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// A GameNight computer that has Ballkickers but not Pinpals, playing a game
/// with two settings.
class FakeRoom {
  final calls = <String>[];
  final bodies = <String, dynamic>{};
  int status = 200;
  bool items = true;
  int stock = 3;
  int revision = 1;

  Map<String, dynamic> get controls => {
        'game': 'ballkickers',
        'instance': 'session-1',
        'revision': revision,
        'can_undo': revision > 1,
        'settings': {
          'items': {'kind': 'toggle', 'label': 'Items', 'description': 'Power-ups', 'value': items},
          'stock': {'kind': 'number', 'label': 'Stock', 'value': stock, 'min': 1, 'max': 9},
          'arena': {
            'kind': 'choice',
            'label': 'Arena',
            'value': 'park',
            'options': ['park', 'beach'],
          },
        },
      };

  late final client = MockClient((request) async {
    final key = '${request.method} ${request.url.path}';
    calls.add('$key ${request.url.query}'.trim());
    if (request.body.isNotEmpty) bodies[key] = jsonDecode(request.body);
    if (status != 200) return http.Response('', status);
    switch (key) {
      case 'GET /api/games':
        return http.Response(
            jsonEncode({
              'games': [
                {
                  'id': 'ballkickers',
                  'title': 'Ballkickers',
                  'selectable': true,
                  'state': 'available'
                },
                {'id': 'pinpals', 'title': 'Pinpals', 'selectable': false, 'state': 'unavailable'},
              ]
            }),
            200);
      case 'POST /api/playlist/queue':
        return http.Response(
            jsonEncode({
              'playlist': {'entries': []}
            }),
            200);
      case 'GET /api/settings':
        return http.Response(jsonEncode(controls), 200);
      case 'POST /api/settings':
        final command = jsonDecode(request.body)['command'] as Map;
        if (command['expected_revision'] != revision) {
          return http.Response('{"error":"stale"}', 409);
        }
        final values = command['values'] as Map;
        items = values['items'] as bool? ?? items;
        stock = values['stock'] as int? ?? stock;
        revision++;
        return http.Response(jsonEncode(controls), 200);
    }
    return http.Response('', 404);
  });
}

class FakeLauncher extends Fake with MockPlatformInterfaceMixin implements UrlLauncherPlatform {
  final opened = <String>[];
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

void main() {
  test('local controls speak as this phone\'s profile', () async {
    final room = FakeRoom();
    final controls = LocalRoomControls(
        GameNightApi(Uri.parse('http://192.168.1.5:3000'), client: room.client), 'prof_me');

    final games = await controls.games();
    expect(games.map((g) => (g.id, g.playable)), [('ballkickers', true), ('pinpals', false)]);
    expect(room.calls.last, 'GET /api/games profile=prof_me');

    await controls.addToQueue('ballkickers');
    expect(room.bodies['POST /api/playlist/queue'], {'profile': 'prof_me', 'game': 'ballkickers'});

    final settings = (await controls.settings())!;
    expect(settings.settings.map((s) => (s.key, s.kind)), [
      ('items', SettingKind.toggle),
      ('stock', SettingKind.number),
      ('arena', SettingKind.choice),
    ]);
    final after = await controls.applySettings(settings, values: {'items': false});
    expect(room.bodies['POST /api/settings'], {
      'profile': 'prof_me',
      'command': {
        'action': 'set',
        'instance': 'session-1',
        'expected_revision': 1,
        'values': {'items': false},
      },
    });
    expect(after!.revision, 2);
    expect(after.settings.first.value, false);
    expect(after.canUndo, isTrue);
    await expectLater(controls.applySettings(settings, values: {'stock': 4}),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 409)));

    // Older hosts and phones that left the room: nothing to offer, no error.
    room.status = 404;
    expect(await controls.games(), isEmpty);
    expect(await controls.settings(), isNull);
    room.status = 403;
    expect(await controls.games(), isEmpty);
  });

  test('settings without values the app understands are left out', () {
    expect(GameSettings.fromJson(null), isNull);
    expect(
        GameSettings.fromJson({
          'game': 'g',
          'instance': 'i',
          'settings': {
            'x': {'kind': 'slider', 'value': 1},
            'y': {'kind': 'toggle', 'value': 'yes'},
          },
        }),
        isNull);
  });

  group('Game tab', () {
    late FakeRoom room;
    late FakeLauncher launcher;
    late AppState state;

    setUp(() async {
      room = FakeRoom();
      launcher = FakeLauncher();
      UrlLauncherPlatform.instance = launcher;
      Catalog.instance = Catalog(
        client: MockClient((_) async =>
            http.Response.bytes(File('test/fixtures/catalog.json').readAsBytesSync(), 200)),
      );
      SharedPreferences.setMockInitialValues({'host': 'http://192.168.1.5:3000'});
      state = AppState(await SharedPreferences.getInstance(),
          apiFactory: (base) => GameNightApi(base, client: room.client));
    });

    tearDown(() => state.dispose());

    Future<void> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: Scaffold(body: GameScreen(state: state, onJoin: () {})),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
    }

    testWidgets('outside a room it is a catalog to browse', (tester) async {
      await show(tester);
      expect(find.text('Ballkickers'), findsOneWidget);
      expect(find.text('Growing Guns'), findsWidgets, reason: 'no cover: title on a coloured tile');
      expect(find.text('1–6 players'), findsOneWidget);
      expect(find.text('GameNight Lobby'), findsNothing);
      expect(find.text('Add to queue'), findsNothing);
      expect(find.text('Join a room'), findsOneWidget);
      expect(room.calls.where((c) => c.contains('/api/games')), isEmpty);

      await tester.tap(find.text('Ballkickers'));
      await tester.pumpAndSettle();
      expect(launcher.opened, isEmpty, reason: 'the game page opens in the app');
      expect(find.text('Chaotic party football: charge shots, dash tackles and diving saves.'),
          findsOneWidget);
      expect(find.text('2 min'), findsOneWidget);
      expect(find.text('Join a room to put this game in the queue.'), findsOneWidget);
      await close(tester);
    });

    testWidgets('in a room, games the host has can be queued and settings changed', (tester) async {
      state.session = const SessionInfo(linked: true, playerId: 'p1', currentTitle: 'Ballkickers');
      await show(tester);

      expect(find.text('Ballkickers settings'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget, reason: 'only for games the host has');
      expect(find.text('Not on this GameNight'), findsNWidgets(2));

      await tester.tap(find.text('Add to queue'));
      await tester.pump();
      await tester.pump();
      expect(room.bodies['POST /api/playlist/queue'],
          {'profile': state.profileId, 'game': 'ballkickers'});
      expect(find.text('Ballkickers is in the queue'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.pump();
      expect((room.bodies['POST /api/settings']['command'] as Map)['values'], {'items': false});
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      await tester.tap(find.byTooltip('More Stock'));
      await tester.pump();
      await tester.pump();
      expect(room.stock, 4);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      await close(tester);
    });
  });
}
