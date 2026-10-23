import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/link.dart';
import 'package:gamenight/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A hosted room whose controller seats are all taken: the phone waits, and
/// asks for a seat of its own.
class FullRoom {
  static const guest = 'test-room-token';
  String status = 'waiting';
  bool phoneSeat = false;
  final calls = <String>[];
  String? joinedAs;
  Map<String, dynamic> get room => {
        'status': status,
        'guest': true,
        'phone_seat': phoneSeat && status != 'connected',
        'room_code': 'ABC234',
        'players': status == 'connected' ? 3 : 2,
        'fresh': true,
        'seat': status == 'connected'
            ? {'index': 2, 'player': 'phone-player', 'revision': 0}
            : null,
        'seats': [
          for (var i = 0; i < 2; i++)
            {
              'index': i,
              'player': 'player-$i',
              'revision': 1,
              'name': 'Player ${i + 1}',
              'available': false
            }
        ],
        'discovery': {
          'current': 'hexstead',
          'games': [],
          'playlist': {'entries': []}
        },
      };
  MockClient client() => MockClient((r) async {
        final key = '${r.method} ${r.url.path}';
        calls.add(key);
        switch (key) {
          case 'POST /v1/rooms/guest':
            joinedAs = jsonDecode(r.body)['profile']['display_name'];
            return http.Response(
                jsonEncode({'token': guest, 'status': room, 'profile': {}}),
                200);
          case 'POST /v1/rooms/phone-seat':
            expect(r.headers['X-GameNight-Room-Token'], guest);
            phoneSeat = true;
            return http.Response('', 204);
          case 'GET /v1/rooms/status':
            return http.Response(jsonEncode(room), 200);
          case 'GET /v1/rooms/companion':
            return http.Response('{}', 200);
          case 'GET /auth/session':
            return http.Response('{}', 401);
        }
        return http.Response('{}', 404);
      });
}

final _preview = GlobalKey();
final _previewDirectory = Platform.environment['PHONE_SEAT_PREVIEW_DIR'];

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = _previewDirectory;
  if (directory == null) return;
  await tester.pump();
  final boundary =
      _preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fonts = Platform.environment['PHONE_SEAT_PREVIEW_FONTS'];
    if (fonts == null) return;
    // Buttons set only a weight, so their labels keep the test font.
    final roboto = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      roboto.addFont(File('$fonts/Roboto-$weight.ttf')
          .readAsBytes()
          .then(ByteData.sublistView));
    }
    await roboto.load();
    final bungee = FontLoader('Bungee')
      ..addFont(rootBundle.load('assets/fonts/Bungee-Regular.ttf'));
    await bungee.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('a waiting phone takes a seat of its own', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final server = FullRoom();
    final state = AppState(await SharedPreferences.getInstance(),
        cloud: CloudApi(client: server.client()));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
        key: _preview,
        child: GameNightApp(
            state: state,
            initialLink: Uri.parse('$hostedOrigin/app/?room=ABC234'))));
    await tester.pumpAndSettle();
    // A new phone names its player before the room shows it.
    expect(find.byKey(const ValueKey('name-dialog')), findsOneWidget);
    expect(server.calls, isNot(contains('POST /v1/rooms/guest')));
    await _capture(tester, 'name-step');
    await tester.enterText(find.byType(TextField).last, 'Joep');
    await tester.tap(find.text('Join room'));
    await tester.pumpAndSettle();
    expect(server.joinedAs, 'Joep');
    expect(state.name, 'Joep');
    final button = find.text('Play on this phone');
    await tester.scrollUntilVisible(button, 200,
        scrollable: find.byType(Scrollable).first);
    await _capture(tester, 'phone-seat-waiting');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(server.calls, contains('POST /v1/rooms/phone-seat'));
    expect(state.hostedRoom!.phoneSeat, isTrue);
    expect(find.text('Adding your player to the party…'), findsOneWidget);
    await _capture(tester, 'phone-seat-asked');
    // The GameNight PC seats the phone on its next check-in.
    server.status = 'connected';
    await state.refreshHostedRoom();
    await tester.pumpAndSettle();
    expect(find.text('Play on this phone'), findsNothing);
    expect(tester.takeException(), isNull);
    state.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
