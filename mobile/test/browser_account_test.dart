import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
      'browser adopts link sign-in and detects expired cookies without treating outages as logout',
      () async {
    var status = 200;
    final api = CloudApi(
        browserCookies: true,
        client: MockClient((request) async {
          expect(request.url.path, '/auth/session');
          expect(request.headers.containsKey('Authorization'), isFalse);
          return http.Response('{"csrf":"adopted-csrf"}', status);
        }));
    expect(api.signedIn, isFalse);
    expect(await api.restoreBrowserSession(), isTrue);
    expect(api.signedIn, isTrue);
    status = 503;
    await expectLater(api.restoreBrowserSession(), throwsA(isA<Exception>()));
    expect(api.signedIn, isTrue);
    status = 401;
    expect(await api.restoreBrowserSession(), isFalse);
    expect(api.signedIn, isFalse);
  });

  test(
      'web sign-in uses invisible cookies and CSRF, never fake bearer credentials',
      () async {
    var loggedIn = false;
    var csrfReads = 0;
    var joined = false;
    final client = MockClient((request) async {
      // A browser supplies Cookie and Origin itself, outside Dart's request.
      expect(request.headers.containsKey('Origin'), isFalse);
      expect(request.headers.containsKey('Cookie'), isFalse);
      expect(request.headers.containsKey('Authorization'), isFalse);
      switch ('${request.method} ${request.url.path}') {
        case 'POST /auth/email/request':
          expect(jsonDecode(request.body)['client'], 'browser');
          return http.Response('', 204); // Set-Cookie is never readable in JS.
        case 'POST /auth/email/verify':
          loggedIn = true;
          return http.Response('', 204);
        case 'GET /auth/session':
          csrfReads++;
          return http.Response('{"csrf":"fixture-csrf"}', loggedIn ? 200 : 401);
        case 'GET /v1/me':
          return http.Response('{"id":"player"}', loggedIn ? 200 : 401);
        case 'POST /v1/rooms/join':
          expect(request.headers['X-GameNight-CSRF'], 'fixture-csrf');
          joined = true;
          return http.Response('', 204);
        case 'DELETE /v1/session':
          expect(request.headers['X-GameNight-CSRF'], 'fixture-csrf');
          loggedIn = false;
          return http.Response('', 204);
      }
      return http.Response('', 404);
    });
    final api = CloudApi(client: client, browserCookies: true);
    await api.requestCode('player@example.com');
    expect(api.emailBinding, isNotNull);
    await api.verifyCode('12345678');
    expect(api.signedIn, isTrue);
    expect((await api.me()).id, 'player');
    await api.joinRoom('ABCDEF');
    expect(joined, isTrue);
    expect(csrfReads, 1);
    await api.signOut();
    expect(api.signedIn, isFalse);
    expect(loggedIn, isFalse);
  });

  test('restored web marker cannot authorize a write without a browser session',
      () async {
    var mutations = 0;
    final api = CloudApi(
      browserCookies: true,
      token: 'browser-cookie-session',
      client: MockClient((request) async {
        if (request.method != 'GET') mutations++;
        expect(request.url.path, '/auth/session');
        return http.Response('', 401);
      }),
    );
    await expectLater(api.joinRoom('ABCDEF'), throwsA(isA<SignedOut>()));
    expect(api.signedIn, isFalse);
    expect(mutations, 0);
  });

  test('web reload obtains CSRF for the current cookie, not a saved token',
      () async {
    final paths = <String>[];
    final api = CloudApi(
      browserCookies: true,
      token: 'browser-cookie-session',
      client: MockClient((request) async {
        paths.add(request.url.path);
        expect(request.headers.containsKey('Authorization'), isFalse);
        if (request.url.path == '/auth/session') {
          return http.Response('{"csrf":"new-session-csrf"}', 200);
        }
        expect(request.headers['X-GameNight-CSRF'], 'new-session-csrf');
        return http.Response('', 204);
      }),
    );
    await api.joinRoom('ABCDEF');
    expect(paths, ['/auth/session', '/v1/rooms/join']);
  });
}
