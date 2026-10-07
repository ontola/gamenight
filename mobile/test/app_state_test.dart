import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/api.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/link.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fake local web server that records what the app sends.
class FakeHost {
  final calls = <String>[];
  final bodies = <String, dynamic>{};
  bool linked = false;

  late final client = MockClient((request) async {
    final key = '${request.method} ${request.url.path}';
    calls.add(key);
    if (request.body.isNotEmpty) bodies[key] = jsonDecode(request.body);
    if (request.url.path == '/api/player-links') return http.Response('{"linked":[]}', 200);
    if (request.url.path == '/api/profiles') return http.Response(request.body, 200);
    if (request.url.path.endsWith('/join')) {
      return http.Response(jsonEncode({'status': 'claimed', 'player_id': 'p1'}), 200);
    }
    if (request.url.path.endsWith('/session')) {
      return http.Response(
          jsonEncode({
            'linked': linked,
            'player_id': linked ? 'p1' : null,
            'players': 2,
            'player_name': 'Panda',
            'seat': 0,
            'current': null,
            'next': 'Neon Trails',
          }),
          200);
    }
    if (request.url.path == '/api/local-room/join') return http.Response('', 204);
    return http.Response('', 404);
  });
}

void main() {
  late FakeHost host;
  late AppState state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = FakeHost();
    state = AppState(await SharedPreferences.getInstance(),
        apiFactory: (base) => GameNightApi(base, client: host.client));
  });

  tearDown(() => state.dispose());

  test('a room code saves the profile, then asks for a lobby pickup', () async {
    await state.connect(parseHostLink('http://10.0.0.2:7913/?r=ABC234'));
    expect(host.calls, containsAllInOrder(['GET /api/player-links', 'POST /api/profiles', 'POST /api/local-room/join']));
    expect(host.bodies['POST /api/local-room/join'],
        {'code': 'ABC234', 'profile': state.profileId});
    expect(host.calls.where((c) => c.endsWith('/join') && c.contains('/profiles/')), isEmpty);
  });

  test('a character QR claims that character and keeps editing it', () async {
    await state.connect(parseHostLink('http://10.0.0.2:7913/studio?claim=p1&link_revision=2'));
    final join = host.bodies['POST /api/profiles/${state.profileId}/join'];
    expect(join, {'claim': 'p1', 'seat': null, 'link_revision': 2});
    expect(state.boundPlayer, 'p1');
    expect(state.sync, SyncState.synced);
  });

  test('a lobby pickup binds the phone and pushes the drawing', () async {
    await state.connect(parseHostLink('http://10.0.0.2:7913/?r=ABC234'));
    host.linked = true;
    final before = host.calls.length;
    await state.refreshSession();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(state.session!.linked, isTrue);
    expect(state.boundPlayer, 'p1');
    expect(host.calls.skip(before), contains('POST /api/profiles/${state.profileId}/join'));
  });

  test('the first random name and face survive a restart', () async {
    final again = AppState(await SharedPreferences.getInstance());
    expect(again.name, state.name);
    expect(again.face, state.face);
    expect(again.profileId, state.profileId);
    again.dispose();
  });

  test('hosted room links are refused with a clear message', () async {
    expect(() => state.connect(parseHostLink('https://gamenight.ontola.io/?r=ABC234')),
        throwsA(isA<LinkError>()));
  });
}
