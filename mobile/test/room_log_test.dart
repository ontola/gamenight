import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/api.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/room_controls.dart';
import 'package:gamenight/screens/room_log_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

int at(int hour, int minute) =>
    DateTime(2026, 10, 23, hour, minute).millisecondsSinceEpoch ~/ 1000;

final log = {
  'entries': [
    {'id': 0, 'at': at(20, 1), 'kind': 'joined', 'text': 'Ann joined'},
    {
      'id': 1,
      'at': at(20, 5),
      'kind': 'game_started',
      'text': 'Started Ballkickers',
      'game': 'ballkickers'
    },
    {'id': 2, 'at': at(20, 9), 'kind': 'future_kind', 'text': 'New run'},
    {'id': 3, 'kind': 'joined', 'text': 'no time, dropped'},
  ]
};

class FakeControls extends RoomControls {
  @override
  Object get target => this;

  @override
  Future<List<ActivityEntry>> activity() async =>
      ActivityEntry.listFromJson(log);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('the local room log is read as this phone\'s profile', () async {
    final asked = <Uri>[];
    final api = GameNightApi(Uri.parse('http://192.168.1.5:3000'),
        client: MockClient((request) async {
      asked.add(request.url);
      return http.Response(jsonEncode(log), 200);
    }));
    final entries = await LocalRoomControls(api, 'prof_me').activity();
    expect(asked.single.path, '/api/activity');
    expect(asked.single.queryParameters, {'profile': 'prof_me'});
    expect(entries.map((e) => e.text),
        ['Ann joined', 'Started Ballkickers', 'New run']);
    expect(entries[1].game, 'ballkickers');
    expect(entries[0].at, DateTime(2026, 10, 23, 20, 1));
  });

  test('hosts from before the room log have none', () async {
    final api = GameNightApi(Uri.parse('http://192.168.1.5:3000'),
        client: MockClient((_) async => http.Response('', 404)));
    expect(await LocalRoomControls(api, 'prof_me').activity(), isEmpty);
  });

  testWidgets('the log shows the newest line first with its time',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RoomLogScreen(state: state, controls: FakeControls()))));
    await tester.pump();
    final texts = tester
        .widgetList<Text>(find.descendant(
            of: find.byKey(const ValueKey('room-log')),
            matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();
    final run = texts.indexOf('New run');
    final joined = texts.indexOf('Ann joined');
    expect(run, greaterThanOrEqualTo(0));
    expect(run, lessThan(joined), reason: 'newest first');
    expect(texts, contains('20:09'));
    expect(find.byIcon(Icons.notes), findsOneWidget,
        reason: 'an unknown kind still shows');
    await tester.pumpWidget(const SizedBox());
  });
}
