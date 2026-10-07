import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/avatar.dart';
import 'package:gamenight/faces.dart';
import 'package:gamenight/link.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const browser = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
const session = 'c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1';

/// gamenight.ontola.io as the app sees it: cookies for sign-in, then a
/// bearer session for everything else.
class FakeCloud {
  final calls = <String>[];
  final bodies = <String, dynamic>{};
  int revision = 3;
  Map<String, dynamic>? workspace;
  String status = 'none';
  bool conflictOnce = false;

  late final client = MockClient((request) async {
    final key = '${request.method} ${request.url.path}';
    calls.add(key);
    if (request.body.isNotEmpty) bodies[key] = jsonDecode(request.body);
    if (request.url.path.startsWith('/auth/email/') &&
        request.headers['Origin'] != 'https://gamenight.ontola.io') {
      return http.Response('', 403);
    }
    switch (key) {
      case 'POST /auth/email/request':
        return http.Response('', 204, headers: {
          'set-cookie': 'gn_email=$browser; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=600'
        });
      case 'POST /auth/email/verify':
        if (request.headers['Cookie'] != 'gn_email=$browser') return http.Response('', 401);
        if (bodies[key]['code'] != '12345678') return http.Response('', 401);
        return http.Response('', 204, headers: {
          'set-cookie': 'gn_session=$session; Path=/; HttpOnly; Secure; SameSite=Lax; '
              'Max-Age=86400,gn_email=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0'
        });
    }
    if (request.headers['Authorization'] != 'Bearer $session') return http.Response('', 401);
    switch (key) {
      case 'GET /v1/me':
        return http.Response(
            jsonEncode({
              'id': 'acc1',
              'profile': {'display_name': 'Joep', 'skin_color': '#c58c85', 'avatar': ''}
            }),
            200);
      case 'GET /v1/me/studio':
        return http.Response(
            jsonEncode({
              'revision': revision,
              'profile': {'display_name': 'Joep', 'skin_color': '#c58c85', 'avatar': ''},
              'workspace': workspace,
            }),
            200);
      case 'PUT /v1/me/studio':
        final body = bodies[key] as Map<String, dynamic>;
        if (conflictOnce || body['revision'] != revision) {
          conflictOnce = false;
          revision++;
          return http.Response('', 409);
        }
        revision++;
        workspace = body['workspace'] as Map<String, dynamic>;
        return http.Response(jsonEncode({...body, 'revision': revision}), 200);
      case 'POST /v1/rooms/join':
        if (bodies[key]['code'] != 'ABC234') return http.Response('', 404);
        status = 'waiting';
        return http.Response('{}', 200);
      case 'GET /v1/rooms/status':
        return http.Response(
            jsonEncode({
              'status': status,
              if (status != 'none') 'room_code': 'ABC234',
              if (status == 'connected') ...{
                'players': 2,
                'fresh': true,
                'discovery': {'current': 'hexstead', 'next': null},
              },
            }),
            200);
      case 'POST /v1/pairing/unlink':
      case 'POST /v1/rooms/cancel':
        status = 'none';
        return http.Response('', 204);
      case 'DELETE /v1/session':
        return http.Response('', 204);
    }
    return http.Response('', 404);
  });
}

void main() {
  late FakeCloud cloud;
  late AppState state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cloud = FakeCloud();
    state = AppState(await SharedPreferences.getInstance(),
        cloud: CloudApi(client: cloud.client));
  });

  tearDown(() => state.dispose());

  test('signing in takes the saved player and keeps this phone’s faces', () async {
    final mine = state.currentArtwork.data;
    final saved = Artwork(id: 'web1', name: 'From the web', data: randomFace());
    cloud.workspace = jsonDecode(encodeBackup(Backup(
        username: 'Joep',
        skinColor: '#c58c85',
        activeArtworkId: 'web1',
        artworks: [saved]))) as Map<String, dynamic>;

    await state.requestSignInCode(' Joep@Example.com ');
    expect(state.accountEmail, 'joep@example.com');
    await expectLater(state.verifySignInCode('00000000'), throwsA(isA<Exception>()));
    // A wrong code keeps the binding so the right one still works.
    await state.requestSignInCode('joep@example.com');
    final message = await state.verifySignInCode('12345678');

    expect(message, contains('saved player'));
    expect(state.signedIn, isTrue);
    expect(state.prefs.getString('cloud_token'), session);
    expect(state.name, 'Joep');
    expect(state.skinColor, '#c58c85');
    expect(state.artworks.map((a) => a.name), contains('From the web'));
    expect(state.artworks.any((a) => encodeAvatar(a.data) == encodeAvatar(mine)), isTrue);
    // Everything goes back up, so the account has this phone's faces too.
    final put = cloud.bodies['PUT /v1/me/studio'] as Map<String, dynamic>;
    expect(put['profile']['display_name'], 'Joep');
    expect((put['workspace']['artworks'] as List).length, 2);
  });

  test('a save that lost a race is retried on the newest revision', () async {
    await state.requestSignInCode('joep@example.com');
    await state.verifySignInCode('12345678');
    cloud.conflictOnce = true;
    state.setName('Panda');
    await state.pushProfile();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect((cloud.bodies['PUT /v1/me/studio'] as Map)['profile']['display_name'], 'Panda');
    expect(cloud.calls.where((c) => c == 'PUT /v1/me/studio').length, greaterThanOrEqualTo(2));
  });

  test('a room code joins an online room after signing in', () async {
    await expectLater(state.joinHostedRoom('ABC234'), throwsA(AppState.signInFirst));
    await state.requestSignInCode('joep@example.com');
    await state.verifySignInCode('12345678');

    await expectLater(state.joinHostedRoom('ZZZ234'), throwsA(isA<Exception>()));
    final message = await state.joinHostedRoom('ABC234');
    expect(message, contains('door'));
    expect(state.inHostedRoom, isTrue);
    expect(state.hostedRoom!.waiting, isTrue);

    cloud.status = 'connected';
    await state.refreshHostedRoom();
    expect(state.hostedRoom!.connected, isTrue);
    expect(state.hostedRoom!.current, 'hexstead');

    await state.leaveHostedRoom();
    expect(state.inHostedRoom, isFalse);
    expect(cloud.calls, contains('POST /v1/pairing/unlink'));
  });

  test('hosted lobby QR codes are understood', () {
    final pair = parseHostLink('https://gamenight.ontola.io/studio#pair=t1');
    expect(pair.hosted, isTrue);
    expect(pair.pair, 't1');
    expect(parseHostLink('https://gamenight.ontola.io/join#room=abc234').roomCode, 'ABC234');
  });

  test('an expired session signs the phone out', () async {
    await state.requestSignInCode('joep@example.com');
    await state.verifySignInCode('12345678');
    state.cloud.token = 'd' * 64;
    await state.prefs.setString('cloud_token', 'd' * 64);
    await state.loadAccount();
    expect(state.signedIn, isFalse);
    expect(state.prefs.getString('cloud_token'), isNull);
  });
}
