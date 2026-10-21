import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/main.dart';
import 'package:gamenight/push_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'hosted_room_test.dart' show roomFixture;

class FakePush implements PushDevice {
  final refresh = StreamController<String>.broadcast();
  final taps = StreamController<String>.broadcast();
  final messages = StreamController<String>.broadcast();
  Future<String?> token = Future.value('device-one');
  String? initial;
  int permissions = 0;
  int deletions = 0;
  Future<void> deletion = Future.value();
  @override
  String get platform => 'ios';
  @override
  Stream<String> get tokens => refresh.stream;
  @override
  Stream<String> get opened => taps.stream;
  @override
  Stream<String> get foreground => messages.stream;
  @override
  Future<String?> initialRoom() async => initial;
  @override
  Future<String?> requestToken() {
    permissions++;
    return token;
  }

  @override
  Future<void> deleteToken() async {
    deletions++;
    await deletion;
  }

  void dispose() {
    refresh.close();
    taps.close();
    messages.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['PUSH_PREVIEW_DIR'] == null) return;
    for (final entry in {
      'Outfit': 'assets/fonts/Outfit-400.ttf',
      'Bungee': 'assets/fonts/Bungee-Regular.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf'
    }.entries) {
      await (FontLoader(entry.key)..addFont(rootBundle.load(entry.value)))
          .load();
    }
  });
  test('registers, refreshes and removes only this phone before logout',
      () async {
    SharedPreferences.setMockInitialValues({'cloud_token': 'account-session'});
    final requests = <http.Request>[];
    final device = FakePush();
    addTearDown(device.dispose);
    final cloud = CloudApi(client: MockClient((request) async {
      requests.add(request);
      return http.Response('', 204);
    }));
    final state = AppState(await SharedPreferences.getInstance(),
        cloud: cloud, pushDevice: device);
    addTearDown(state.dispose);
    await state.push.sync();
    await state.push.sync();
    expect(requests.length, 1);
    expect(requests.single.headers['Authorization'], 'Bearer account-session');
    expect(jsonDecode(requests.single.body),
        {'token': 'device-one', 'platform': 'ios'});
    device.refresh.add('device-two');
    await Future<void>.delayed(Duration.zero);
    await state.signOut();
    expect(requests.map((r) => '${r.method} ${r.url.path}').toList(), [
      'POST /v1/me/push-token',
      'POST /v1/me/push-token',
      'DELETE /v1/me/push-token',
      'DELETE /v1/me/push-token',
      'DELETE /v1/session',
    ]);
    expect(jsonDecode(requests[2].body)['token'], 'device-one');
    expect(jsonDecode(requests[3].body)['token'], 'device-two');
    expect(device.deletions, 1);
    device.refresh.add('after-logout');
    await Future<void>.delayed(Duration.zero);
    expect(requests.length, 5);
  });

  test('denied permission and guest sessions do not register', () async {
    final requests = <http.Request>[];
    final device = FakePush()..token = Future.value(null);
    final cloud = CloudApi(client: MockClient((r) async {
      requests.add(r);
      return http.Response('', 204);
    }));
    final push = AccountPush(cloud, device);
    addTearDown(() {
      push.dispose();
      cloud.close();
      device.dispose();
    });
    cloud.guestToken = 'guest';
    await push.sync();
    expect(device.permissions, 0);
    cloud.token = 'account';
    await push.sync();
    expect(device.permissions, 1);
    expect(requests, isEmpty);
  });

  test('token arriving after logout cannot register again', () async {
    final token = Completer<String?>();
    final requests = <http.Request>[];
    final device = FakePush()..token = token.future;
    final cloud = CloudApi(
        token: 'session',
        client: MockClient((r) async {
          requests.add(r);
          return http.Response('', 204);
        }));
    final push = AccountPush(cloud, device);
    addTearDown(() {
      push.dispose();
      cloud.close();
      device.dispose();
    });
    final syncing = push.sync();
    await push.signOut();
    token.complete('late');
    await syncing;
    expect(requests, isEmpty);
  });

  test('an offline push endpoint does not break signout', () async {
    final device = FakePush();
    final cloud = CloudApi(
        token: 'session',
        client: MockClient((_) async => throw Exception('offline')));
    final push = AccountPush(cloud, device);
    addTearDown(() {
      push.dispose();
      cloud.close();
      device.dispose();
    });
    await push.sync();
    await push.signOut();
    expect(device.deletions, 1);
  });

  testWidgets('logout finishes if native token revocation stalls',
      (tester) async {
    final device = FakePush()..deletion = Completer<void>().future;
    final cloud = CloudApi(token: 'session');
    final push = AccountPush(cloud, device);
    var finished = false;
    final logout = push.signOut().then((_) => finished = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await logout;
    expect(finished, isTrue);
    push.dispose();
    cloud.close();
    device.dispose();
  });

  for (final cold in [false, true]) {
    testWidgets(
        '${cold ? "Cold" : "Warm"} notification opens authenticated room',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {'cloud_token': 'session', 'player_name': 'Test Player'});
      final device = FakePush()..initial = cold ? 'TEST42' : null;
      final requests = <http.Request>[];
      final state = AppState(await SharedPreferences.getInstance(),
          cloud: CloudApi(client: MockClient((r) async {
        requests.add(r);
        if (r.url.path == '/v1/rooms/status') {
          return http.Response(jsonEncode(roomFixture()), 200);
        }
        if (r.url.path == '/v1/rooms/companion') {
          return http.Response('{}', 200);
        }
        if (r.url.path == '/v1/me') return http.Response('{"id":"test"}', 200);
        if (r.url.path == '/v1/catalog') {
          return http.Response('{"games":[]}', 200);
        }
        return http.Response('{}', 200);
      })));
      addTearDown(device.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preview = GlobalKey();
      final loading = Completer<void>();
      await tester.pumpWidget(RepaintBoundary(
          key: preview,
          child: GameNightApp(
              state: state,
              pushDevice: device,
              accountLoading: loading.future)));
      await tester.pump();
      if (!cold) device.taps.add('TEST42');
      await tester.pump();
      expect(state.inHostedRoom, isFalse,
          reason: 'Wait for account restoration');
      loading.complete();
      await tester.pumpAndSettle();
      expect(state.inHostedRoom, isTrue);
      expect(state.hostedRoom?.connected, isTrue);
      expect(
          requests
              .where((r) => r.url.path == '/v1/rooms/status')
              .every((r) => r.headers['Authorization'] == 'Bearer session'),
          isTrue);
      expect(find.textContaining('Connected as'), findsWidgets);
      // A second tap from another tab returns to Room, including warm launches.
      await tester.tap(find.text('Games').last);
      await tester.pumpAndSettle();
      device.taps.add('TEST42');
      await tester.pumpAndSettle();
      expect(find.textContaining('Connected as').hitTestable(), findsWidgets);
      device.messages.add('TEST42');
      await tester.pumpAndSettle();
      expect(find.text("You're in room TEST42"), findsOneWidget);
      final directory = Platform.environment['PUSH_PREVIEW_DIR'];
      if (directory != null && !cold) {
        await tester.runAsync(() async {
          final boundary = preview.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File('$directory/room-push.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }
}
