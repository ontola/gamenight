import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/api.dart';
import 'package:gamenight/room_controls.dart';
import 'package:gamenight/screens/settings_panel.dart';
import 'package:gamenight/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

GameSettings snapshot(
        {int stock = 3,
        bool items = true,
        int revision = 1,
        String instance = 'session'}) =>
    GameSettings(
        game: 'downhill-rush',
        instance: instance,
        revision: revision,
        canUndo: revision > 1,
        settings: [
          Setting(
              key: 'stock',
              label: 'Lives',
              kind: SettingKind.number,
              value: stock,
              min: 1,
              max: 9),
          Setting(
              key: 'items',
              label: 'Obstacles',
              kind: SettingKind.toggle,
              value: items),
          const Setting(
              key: 'arena',
              label: 'Mountain',
              kind: SettingKind.choice,
              value: 'Forest',
              options: ['Forest', 'Snow']),
        ]);

class SlowControls extends RoomControls {
  @override
  Object get target => this;
  GameSettings current = snapshot();
  Completer<GameSettings?>? delayedRead;
  final writes = <({
    GameSettings base,
    Map<String, Object> values,
    Completer<GameSettings?> reply
  })>[];
  @override
  Future<GameSettings?> settings({String? game}) {
    final delayed = delayedRead;
    delayedRead = null;
    return delayed?.future ?? Future.value(current);
  }

  @override
  Future<GameSettings?> applySettings(GameSettings current,
      {Map<String, Object> values = const {},
      SettingsAction action = SettingsAction.set}) {
    final reply = Completer<GameSettings?>();
    writes.add((base: current, values: Map.of(values), reply: reply));
    return reply.future;
  }

  void confirm(int index, GameSettings next) {
    current = next;
    writes[index].reply.complete(next);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final preview = GlobalKey();
Future<void> show(WidgetTester tester, RoomControls controls) async {
  await tester.pumpWidget(MaterialApp(
      theme: gameNightTheme(),
      home: RepaintBoundary(
          key: preview,
          child: Scaffold(
              appBar: AppBar(title: const Text('Downhill Rush')),
              body: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child:
                      SettingsSection(controls: controls, showEmpty: true))))));
  await tester.pump();
}

Future<void> capture(WidgetTester tester) async {
  final folder = Platform.environment['SETTINGS_PREVIEW_DIR'];
  if (folder == null) return;
  await tester.pump(const Duration(milliseconds: 250));
  final boundary =
      preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(folder).create(recursive: true);
    await File('$folder/settings-saving.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

Map<String, Object?> wire(
        {int revision = 2, int stock = 4, String instance = 'session'}) =>
    {
      'game': 'downhill-rush',
      'instance': instance,
      'revision': revision,
      'settings': {
        'stock': {'kind': 'number', 'value': stock}
      },
    };

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fonts = Platform.environment['SETTINGS_PREVIEW_FONTS'];
    if (fonts == null) return;
    final text = FontLoader('Roboto');
    for (final weight in ['Regular', 'Bold']) {
      text.addFont(File('$fonts/Roboto-$weight.ttf')
          .readAsBytes()
          .then(ByteData.sublistView));
    }
    await text.load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  testWidgets(
      'rapid taps update immediately and serialize/coalesce without disabling controls',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final room = SlowControls();
    await show(tester, room);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('More Lives'));
    }
    await tester.pump();
    expect(find.text('6'), findsOneWidget);
    expect(room.writes.length, 1);
    expect(room.writes[0].values, {'stock': 4});
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(room.writes.length, 1);
    await capture(tester);
    room.confirm(0, snapshot(stock: 4, revision: 2));
    await tester.pump();
    expect(find.text('6'), findsOneWidget);
    expect(room.writes.length, 2);
    expect(room.writes[1].base.revision, 2);
    expect(room.writes[1].values, {'stock': 6, 'items': false});
    room.confirm(1, snapshot(stock: 6, items: false, revision: 3));
    await tester.pump();
    expect(find.text('Saving…'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('old poll cannot roll back a confirmed edit', (tester) async {
    final room = SlowControls();
    await show(tester, room);
    final read = room.delayedRead = Completer<GameSettings?>();
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byTooltip('More Lives'));
    room.confirm(0, snapshot(stock: 4, revision: 2));
    await tester.pump();
    read.complete(snapshot());
    await tester.pump();
    expect(find.text('4'), findsOneWidget);
    expect(find.text('3'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'rejection retains latest intent and retries against refreshed revision',
      (tester) async {
    final room = SlowControls();
    await show(tester, room);
    await tester.tap(find.byTooltip('More Lives'));
    await tester.tap(find.byTooltip('More Lives'));
    room.current = snapshot(stock: 2, revision: 8);
    room.writes[0].reply
        .completeError(const ApiError('Changed on another phone.', 409));
    await tester.pump();
    expect(find.text('5'), findsOneWidget);
    expect(find.text('Changed on another phone.'), findsOneWidget);
    expect(find.text('Not saved'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(room.writes[1].base.revision, 8);
    expect(room.writes[1].values, {'stock': 5});
    room.confirm(1, snapshot(stock: 5, revision: 9));
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-error')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching rooms drops queued intent and ignores old responses',
      (tester) async {
    final old = SlowControls(), next = SlowControls();
    next.current = snapshot(stock: 8, instance: 'new-room');
    await show(tester, old);
    await tester.tap(find.byTooltip('More Lives'));
    await tester.tap(find.byTooltip('More Lives'));
    await show(tester, next);
    old.confirm(0, snapshot(stock: 4, revision: 2));
    await tester.pump();
    expect(find.text('8'), findsOneWidget);
    expect(old.writes.length, 1);
    expect(next.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'new game instance clears pending changes instead of replaying them',
      (tester) async {
    final room = SlowControls();
    await show(tester, room);
    await tester.tap(find.byTooltip('More Lives'));
    await tester.tap(find.byTooltip('More Lives'));
    room.confirm(0, snapshot(stock: 2, instance: 'next-round'));
    await tester.pump();
    expect(room.writes.length, 1);
    expect(find.text('2'), findsOneWidget);
    expect(find.textContaining('Unsaved changes were cleared'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('cloud waits for its own receipt, not an unrelated revision change',
      () async {
    var id = '', polls = 0;
    final cloud = CloudApi(client: MockClient((request) async {
      if (request.method == 'POST') {
        id = jsonDecode(request.body)['request_id'] as String;
        return http.Response('', 202);
      }
      polls++;
      return http.Response(
          jsonEncode({
            'controls': wire(revision: polls + 1),
            'requests': [
              {'id': id, 'state': polls == 1 ? 'queued' : 'complete'}
            ]
          }),
          200);
    }));
    final result = await CloudRoomControls(cloud)
        .applySettings(snapshot(), values: {'stock': 4});
    expect(polls, 2);
    expect(result!.revision, 3);
    cloud.close();
  });

  test('cloud surfaces host rejection and instance changes', () async {
    for (final changedSession in [false, true]) {
      var id = '';
      final cloud = CloudApi(client: MockClient((request) async {
        if (request.method == 'POST') {
          id = jsonDecode(request.body)['request_id'] as String;
          return http.Response('', 202);
        }
        return http.Response(
            jsonEncode({
              'controls': wire(instance: changedSession ? 'new' : 'session'),
              'requests': [
                {'id': id, 'state': 'failed', 'result': 'Round already ended.'}
              ]
            }),
            200);
      }));
      await expectLater(
          CloudRoomControls(cloud)
              .applySettings(snapshot(), values: {'stock': 4}),
          throwsA(isA<ApiError>().having(
              (e) => e.message,
              'reason',
              changedSession
                  ? contains('game changed')
                  : 'Round already ended.')));
      cloud.close();
    }
  });

  test('cloud confirmation has a total deadline and stops polling afterwards',
      () async {
    var requests = 0;
    final slow = Completer<http.Response>();
    final cloud = CloudApi(client: MockClient((request) async {
      requests++;
      if (request.method == 'POST') return http.Response('', 202);
      return slow.future;
    }));
    await expectLater(
        CloudRoomControls(cloud,
                confirmationTimeout: const Duration(milliseconds: 40))
            .applySettings(snapshot(), values: {'stock': 4}),
        throwsA(isA<ApiError>()
            .having((e) => e.message, 'timeout', contains('not confirmed'))));
    expect(requests, 2);
    slow.complete(
        http.Response(jsonEncode({'controls': wire(), 'requests': []}), 200));
    await Future<void>.delayed(const Duration(milliseconds: 550));
    expect(requests, 2,
        reason: 'A late HTTP response must not resume the polling loop');
    cloud.close();
  });
}
