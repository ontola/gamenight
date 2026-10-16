import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/link.dart';
import 'package:gamenight/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GuestCloud {
  static const guest = 'test-room-token';
  static final auth = List.filled(64, 'a').join();
  String status = 'choose_player';
  bool expired = false;
  bool phone = true;
  bool upgraded = false;
  final calls = <String>[];
  final bodies = <String, dynamic>{};
  Map<String, dynamic> get room => {
        'status': status,
        'guest': !upgraded,
        'room_code': 'ABC234',
        'players': 2,
        'fresh': true,
        'seat': status == 'connected'
            ? {'index': 1, 'player': 'same-player', 'revision': 4}
            : null,
        'seats': [
          for (var i = 0; i < 2; i++)
            {
              'index': i,
              'player': 'player-$i',
              'revision': 4,
              'name': 'Player ${i + 1}',
              'available': true
            }
        ],
        'discovery': {
          'current': 'pocket-aces',
          'games': [],
          'playlist': {'entries': []}
        },
      };
  MockClient client() => MockClient((r) async {
        final key = '${r.method} ${r.url.path}';
        calls.add(key);
        if (r.body.isNotEmpty) bodies[key] = jsonDecode(r.body);
        switch (key) {
          case 'POST /v1/rooms/guest':
            expect(r.headers.containsKey('Authorization'), isFalse);
            if (bodies[key]['ticket'] != null) status = 'connected';
            return http.Response(
                jsonEncode({
                  'token': guest,
                  'status': room,
                  'profile': bodies[key]['profile']
                }),
                200);
          case 'POST /v1/rooms/guest/seat':
            expect(r.headers['X-GameNight-Room-Token'], guest);
            expect(
                bodies[key], {'index': 1, 'player': 'player-1', 'revision': 4});
            status = 'connected';
            return http.Response('', 204);
          case 'GET /v1/rooms/status':
            if (!upgraded) expect(r.headers['X-GameNight-Room-Token'], guest);
            return http.Response(jsonEncode(room), expired ? 401 : 200);
          case 'GET /v1/rooms/companion':
            if (!upgraded) expect(r.headers['X-GameNight-Room-Token'], guest);
            return http.Response(
                jsonEncode(phone
                    ? {
                        'game': 'pocket-aces',
                        'title': 'Pocket Aces',
                        'url': '/v1/companion/private-test/index.html'
                      }
                    : {}),
                200);
          case 'POST /v1/rooms/guest/leave':
            expect(r.headers['X-GameNight-Room-Token'], guest);
            return http.Response('', 204);
          case 'POST /auth/email/request':
            expect(r.headers.containsKey('X-GameNight-Room-Token'), isFalse);
            return http.Response('', 204,
                headers: {'set-cookie': 'gn_email=binding; Path=/; HttpOnly'});
          case 'POST /auth/email/verify':
            return http.Response('', 204,
                headers: {'set-cookie': 'gn_session=$auth; Path=/; HttpOnly'});
          case 'GET /v1/me':
            expect(r.headers.containsKey('X-GameNight-Room-Token'), isFalse);
            return http.Response('{"id":"saved-account"}', 200);
          case 'GET /v1/me/studio':
            return http.Response('{"revision":0,"workspace":null}', 200);
          case 'PUT /v1/me/studio':
            return http.Response(
                jsonEncode({...bodies[key], 'revision': 1}), 200);
          case 'POST /v1/rooms/guest/upgrade':
            expect(r.headers['Authorization'], 'Bearer $auth');
            expect(r.headers['X-GameNight-Room-Token'], guest);
            upgraded = true;
            return http.Response(jsonEncode(room), 200);
          case 'GET /auth/session':
            return http.Response('{}', 401);
          case 'GET /v1/me/ai-credits':
            expect(r.headers.containsKey('X-GameNight-Room-Token'), isFalse);
            return http.Response('{}', 403);
        }
        return http.Response('{}', 404);
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GuestCloud server;
  late AppState state;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = GuestCloud();
    state = AppState(await SharedPreferences.getInstance(),
        cloud: CloudApi(client: server.client()));
  });
  tearDown(() => state.dispose());

  test('room code joins as guest and seat choice opens private phone game',
      () async {
    await state.joinHostedRoom('ABC234');
    expect(state.signedIn, isFalse);
    expect(state.isGuest, isTrue);
    expect(state.hostedRoom!.choosingPlayer, isTrue);
    expect(server.calls.any((c) => c.contains('/auth/')), isFalse);
    await state.chooseGuestSeat(state.hostedRoom!.seats[1]);
    expect(state.hostedRoom!.connected, isTrue);
    expect(state.companion!.game, 'pocket-aces');
    expect(state.cloud.token, isNull);
    expect(state.prefs.getString('guest_room_token'), GuestCloud.guest);
    await expectLater(state.cloud.request('GET', '/v1/me/ai-credits'),
        throwsA(isA<Exception>()));
  });

  test('personal QR immediately binds without sign-in', () async {
    await state.connect(parseHostLink('$hostedOrigin/studio#pair=seat-ticket'));
    expect(state.hostedRoom!.connected, isTrue);
    expect(server.bodies['POST /v1/rooms/guest']['ticket'], 'seat-ticket');
    expect(state.companion, isNotNull);
    expect(state.signedIn, isFalse);
  });

  test('reload retains guest connection despite no browser account cookie',
      () async {
    await state.claimHostedSeat('seat-ticket');
    final restored = AppState(state.prefs,
        cloud: CloudApi(client: server.client(), browserCookies: true));
    addTearDown(restored.dispose);
    await restored.loadAccount();
    expect(restored.signedIn, isFalse);
    expect(restored.isGuest, isTrue);
    expect(restored.inHostedRoom, isTrue);
    expect(restored.companion!.game, 'pocket-aces');
  });

  test(
      'expired guest asks for QR again and clears credential without sign-in gate',
      () async {
    await state.claimHostedSeat('seat-ticket');
    server.expired = true;
    await state.refreshHostedRoom();
    expect(state.isGuest, isFalse);
    expect(state.inHostedRoom, isFalse);
    expect(state.companion, isNull);
    expect(state.prefs.getString('guest_room_token'), isNull);
    expect(state.sessionError, contains('Scan the QR'));
  });

  test('optional account sign-in upgrades the same seat and revokes room token',
      () async {
    await state.claimHostedSeat('seat-ticket');
    final seat = state.hostedRoom!.raw['seat'];
    await state.requestSignInCode('player@example.com');
    await state.verifySignInCode('12345678');
    expect(state.signedIn, isTrue);
    expect(state.isGuest, isFalse);
    expect(state.hostedRoom!.raw['seat'], seat);
    expect(state.companion!.game, 'pocket-aces');
    expect(state.prefs.getString('guest_room_token'), isNull);
  });

  testWidgets('cold scanned URL shows player picker, never email form',
      (tester) async {
    server.phone = false;
    await tester.pumpWidget(GameNightApp(
        state: state,
        initialLink: Uri.parse('$hostedOrigin/app/?room=ABC234')));
    await tester.pumpAndSettle();
    expect(find.text('Choose your player'), findsOneWidget);
    expect(find.text('Email me a code'), findsNothing);
    await tester.tap(find.text('Player 2'));
    await tester.pumpAndSettle();
    expect(state.hostedRoom!.connected, isTrue);
    expect(find.text('Game settings'), findsNothing);
    expect(tester.takeException(), isNull);
    await state.leaveHostedRoom();
    await tester.pumpWidget(const SizedBox());
  });
}
