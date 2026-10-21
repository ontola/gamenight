import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:gamenight/main.dart';
import 'package:gamenight/reports.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/room_controls.dart';
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
  setUpAll(() async {
    final fonts = Platform.environment['ROOM_PREVIEW_FONTS'];
    if (fonts == null) return;
    for (final family in ['Roboto', 'Ahem']) {
      final loader = FontLoader(family);
      for (final weight in ['Regular', 'Bold']) {
        loader.addFont(File('$fonts/Roboto-$weight.ttf')
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
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

  test('a signed-in phone waiting at its door can take a free player',
      () async {
    SharedPreferences.setMockInitialValues(
        {'cloud_token': 'test-only', 'hosted_room': true});
    var status = <String, dynamic>{
      'status': 'waiting',
      'room_code': 'TEST42',
      'seats': [
        {'index': 0, 'player': 'p1', 'revision': 0, 'available': false},
      ],
    };
    Object? chosen;
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer test-only');
      expect(request.headers.containsKey('X-GameNight-Room-Token'), isFalse);
      if (request.url.path == '/v1/rooms/guest/seat') {
        chosen = jsonDecode(request.body);
        status = roomFixture();
        return http.Response('{"status":"connected"}', 200);
      }
      if (request.url.path == '/v1/rooms/status') {
        return http.Response(jsonEncode(status), 200);
      }
      return http.Response('{}', 200);
    });
    final state = AppState(await SharedPreferences.getInstance(),
        cloud: CloudApi(client: client));
    addTearDown(state.dispose);
    await state.refreshHostedRoom();
    expect(state.hostedRoom!.waiting, isTrue);
    expect(state.hostedRoom!.canChoosePlayer, isFalse);
    // Someone presses A: Player 2 appears and is free.
    (status['seats'] as List)
        .add({'index': 1, 'player': 'p2', 'revision': 0, 'available': true});
    await state.refreshHostedRoom();
    expect(state.hostedRoom!.canChoosePlayer, isTrue);
    await state.chooseGuestSeat(state.hostedRoom!.seats[1]);
    expect(chosen, {'index': 1, 'player': 'p2', 'revision': 0});
    expect(state.hostedRoom!.connected, isTrue);
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
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = GlobalKey();
    final reports = ReportService(await SharedPreferences.getInstance(),
        client: MockClient((_) async => http.Response('{}', 200)));
    addTearDown(reports.close);
    await tester.pumpWidget(RepaintBoundary(
        key: preview, child: GameNightApp(state: state, reports: reports)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // Game, playlist and room share one screen; no tabs inside the room.
    expect(find.byType(SegmentedButton<int>), findsNothing);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('playlist-peek')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Tonight’s playlist'), findsOneWidget);
    expect(find.text('Neon Siege'), findsOneWidget);
    expect(find.text('Join a room'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlist-peek')));
    await tester.pumpAndSettle();
    expect(
        find.text('Drag to reorder. Tap a game for options.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    final directory = Platform.environment['ROOM_PREVIEW_DIR'];
    if (directory != null) {
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        final boundary = preview.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/room-one-screen.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  test('leaving always works; a room that ended disappears by itself',
      () async {
    SharedPreferences.setMockInitialValues(
        {'cloud_token': 'test-only', 'hosted_room': true});
    var status = roomFixture();
    final client = MockClient((request) async {
      if (request.url.path == '/v1/rooms/status') {
        return http.Response(jsonEncode(status), 200);
      }
      if (request.url.path == '/v1/pairing/unlink') {
        return http.Response('', 404);
      }
      return http.Response('', 204);
    });
    final state = AppState(await SharedPreferences.getInstance(),
        cloud: CloudApi(client: client));
    addTearDown(state.dispose);
    await state.refreshHostedRoom();
    expect(state.hostedRoom?.connected, isTrue);
    await state.leaveHostedRoom();
    expect(state.inHostedRoom, isFalse);
    expect(state.prefs.getBool('hosted_room'), isNull);
    expect(state.signedIn, isTrue);

    await state.prefs.setBool('hosted_room', true);
    final again = AppState(state.prefs, cloud: CloudApi(client: client));
    addTearDown(again.dispose);
    status = {'status': 'none'};
    await again.refreshHostedRoom();
    expect(again.inHostedRoom, isFalse);
    expect(again.hostedRoom, isNull);
  });
}
