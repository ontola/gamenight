import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/link.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late bool loggedIn;
  late bool rejectJoin;
  late int joins;
  late Map<String, dynamic> requestBody;
  late MockClient client;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    loggedIn = false;
    rejectJoin = false;
    joins = 0;
    requestBody = {};
    client = MockClient((request) async {
      switch ('${request.method} ${request.url.path}') {
        case 'POST /auth/email/request':
          requestBody = jsonDecode(request.body);
          return http.Response('', 204);
        case 'POST /auth/email/verify':
          loggedIn = true;
          return http.Response('', 204);
        case 'GET /auth/session':
          return http.Response('{"csrf":"test-csrf"}', loggedIn ? 200 : 401);
        case 'GET /v1/me':
          return http.Response('{"id":"test-player"}', loggedIn ? 200 : 401);
        case 'GET /v1/me/studio':
          return http.Response('{"revision":0,"workspace":null}', 200);
        case 'PUT /v1/me/studio':
          return http.Response(
              jsonEncode({...jsonDecode(request.body), 'revision': 1}), 200);
        case 'POST /v1/rooms/join':
        case 'POST /v1/pairing/claim':
          joins++;
          return http.Response('{}', rejectJoin ? 404 : 200);
        case 'GET /v1/rooms/status':
          return http.Response(
              '{"status":"waiting","room_code":"ABC234"}', 200);
      }
      return http.Response('{}', 404);
    });
  });
  AppState state() =>
      AppState(prefs, cloud: CloudApi(client: client, browserCookies: true));

  test('scan sends destination in email request and pasted code resumes once',
      () async {
    final app = state();
    addTearDown(app.dispose);
    await app.rememberRoomInvitation(
        parseHostLink('$hostedOrigin/studio#room=ABC234'));
    await app.requestSignInCode('test@example.com');
    expect(requestBody['return_to'], '/app/?room=ABC234');
    expect(requestBody['client'], 'browser');
    await app.verifySignInCode('12345678');
    expect(app.inHostedRoom, isTrue);
    expect(app.pendingRoomDestination, isNull);
    await app.resumeRoomInvitation(); // original sign-in route continuation
    expect(joins, 1);
  });

  test('email in new tab restores the saved room with its browser session',
      () async {
    final oldTab = state();
    await oldTab.rememberRoomInvitation(
        parseHostLink('$hostedOrigin/studio#room=ABC234'));
    oldTab.dispose();
    loggedIn = true; // email link has verified the browser cookie
    final newTab = state();
    addTearDown(newTab.dispose);
    await newTab.loadAccount();
    expect(newTab.inHostedRoom, isTrue);
    expect(joins, 1);
    expect(newTab.completedRoomInvitation, '/app/?room=ABC234');
    await newTab.loadAccount();
    expect(joins, 1);
  });

  test('unavailable room is not swallowed or forgotten after sign-in',
      () async {
    final app = state();
    addTearDown(app.dispose);
    await app.rememberRoomInvitation(
        parseHostLink('$hostedOrigin/app/?room=ABC234'));
    loggedIn = true;
    rejectJoin = true;
    await app.loadAccount();
    expect(app.inHostedRoom, isFalse);
    expect(app.sessionError, isNotEmpty);
    expect(app.pendingRoomDestination, '/app/?room=ABC234');
    rejectJoin = false;
    await app.resumeRoomInvitation();
    expect(app.inHostedRoom, isTrue);
  });

  test('seat QR resumes concurrent continuations with only one claim',
      () async {
    final app = state();
    addTearDown(app.dispose);
    await app.rememberRoomInvitation(
        parseHostLink('$hostedOrigin/studio#pair=test-seat'));
    loggedIn = true;
    await app.cloud.restoreBrowserSession();
    await Future.wait([app.resumeRoomInvitation(), app.resumeRoomInvitation()]);
    expect(joins, 1);
    expect(app.completedRoomInvitation, '/app/?pair=test-seat');
  });

  test('stale invitations do not unexpectedly rejoin a room', () async {
    final app = state();
    addTearDown(app.dispose);
    await app.rememberRoomInvitation(
        parseHostLink('$hostedOrigin/app/?room=ABC234'));
    await prefs.setInt(
        'pending_room_at',
        DateTime.now()
            .subtract(const Duration(minutes: 11))
            .millisecondsSinceEpoch);
    loggedIn = true;
    await app.loadAccount();
    expect(joins, 0);
  });

  test('return URLs preserve pair priority and reject non-GameNight origins',
      () {
    expect(
        parseHostLink('$hostedOrigin/app/?room=ABC234&pair=seat-ticket')
            .appDestination,
        '/app/?pair=seat-ticket');
    expect(parseHostLink('https://example.org/app/?room=ABC234').appDestination,
        isNull);
    expect(parseHostLink('$hostedOrigin/app/?room=invalid').appDestination,
        isNull);
  });
}
