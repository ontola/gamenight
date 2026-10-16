import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/room_controls.dart';
import 'package:gamenight/screens/room_screen.dart';
import 'package:gamenight/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> roomFixture() => {
      'status': 'connected',
      'room_code': 'TEST42',
      'players': 2,
      'fresh': true,
      'discovery': {
        'current': 'pocket-aces',
        'next': 'neon-siege',
        'games': [],
        'playlist': {
          'current': 0,
          'entries': [
            {'game': 'pocket-aces', 'title': 'Pocket Aces'},
            {'game': 'neon-siege', 'title': 'Neon Siege'},
            {'game': 'ballkickers', 'title': 'Ballkickers'},
          ]
        }
      }
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('hosted companion uses bearer discovery and clears when unlinked',
      () async {
    SharedPreferences.setMockInitialValues(
        {'cloud_token': 'test-only', 'hosted_room': true});
    var status = roomFixture();
    var path = '/v1/companion/test-cap/index.html';
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer test-only');
      if (request.url.path == '/v1/rooms/status') {
        return http.Response(jsonEncode(status), 200);
      }
      if (request.url.path == '/v1/rooms/companion') {
        return http.Response(
            jsonEncode(
                {'game': 'pocket-aces', 'title': 'Pocket Aces', 'url': path}),
            200);
      }
      return http.Response('', 204);
    });
    final state = AppState(await SharedPreferences.getInstance(),
        cloud: CloudApi(client: client));
    addTearDown(state.dispose);
    await state.refreshHostedRoom();
    expect(state.api, isNull);
    expect(state.companion?.title, 'Pocket Aces');
    expect(state.companionError, isNull);
    path = 'https://untrusted.example/private';
    await state.refreshHostedRoom();
    expect(state.companion, isNull);
    expect(state.companionError, isNotNull);
    path = '/v1/companion/test-cap/index.html';
    await state.refreshHostedRoom();
    status = {'status': 'none'};
    await state.refreshHostedRoom();
    expect(state.companion, isNull);
    expect(state.companionError, isNull);
  });

  test(
      'hosted playlist edits carry exact snapshot and wait for reflected queue',
      () async {
    final room = roomFixture();
    Map? sent;
    final cloud = CloudApi(
        token: 'test-only',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            sent = jsonDecode(request.body) as Map;
            final edit = sent!['edit'] as Map;
            final playlist = (room['discovery'] as Map)['playlist'] as Map;
            expect(edit['expected'], playlist);
            final entries = playlist['entries'] as List;
            entries.removeAt(edit['from'] as int);
            return http.Response('{}', 200);
          }
          return http.Response(jsonEncode(room), 200);
        }));
    addTearDown(cloud.close);
    final controls = CloudRoomControls(cloud);
    final before = await controls.playlist();
    final after = await controls.removePlaylistEntry(before, 1);
    expect(sent!['edit']['remove'], true);
    expect(after.entries.map((e) => e.game), ['pocket-aces', 'ballkickers']);
  });

  testWidgets('online room contains playlist without asking to join again',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'cloud_token': 'test-only', 'hosted_room': true});
    final room = roomFixture();
    final state = AppState(await SharedPreferences.getInstance(),
        cloud: CloudApi(
            client:
                MockClient((_) async => http.Response(jsonEncode(room), 200))));
    state.hostedRoom = HostedRoom(room);
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: Scaffold(body: RoomScreen(state: state))));
    await tester.pump();
    await tester.tap(find.text('Playlist').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Tonight’s playlist'), findsOneWidget);
    expect(find.text('Neon Siege'), findsOneWidget);
    expect(find.text('Join a room'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
