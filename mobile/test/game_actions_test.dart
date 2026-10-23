import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/api.dart';
import 'package:gamenight/room_controls.dart';
import 'package:gamenight/screens/settings_panel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final offered = {
  'game': 'spellstorm',
  'title': 'Spellstorm',
  'actions': [
    {
      'key': 'new_run',
      'label': 'New run',
      'description': 'Ends this run for everyone.',
      'confirm': true
    },
    {'key': 'shrug'},
  ]
};

class FakeControls extends RoomControls {
  final pressed = <String>[];

  @override
  Object get target => this;

  @override
  Future<GameActions?> actions() async => GameActions.fromJson(offered);

  @override
  Future<void> triggerAction(String game, String key) async =>
      pressed.add('$game/$key');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a local phone presses a button as its own profile', () async {
    final asked = <http.Request>[];
    final api = GameNightApi(Uri.parse('http://192.168.1.5:3000'),
        client: MockClient((request) async {
      asked.add(request);
      return http.Response(
          jsonEncode(request.method == 'GET' ? offered : {'ok': true}), 200);
    }));
    final controls = LocalRoomControls(api, 'prof_me');
    final actions = await controls.actions();
    expect(asked.first.url.path, '/api/actions');
    expect(asked.first.url.queryParameters, {'profile': 'prof_me'});
    expect(actions!.actions.map((a) => a.label), ['New run'],
        reason: 'a button without a label is dropped');
    expect(actions.actions.single.confirm, isTrue);
    await controls.triggerAction('spellstorm', 'new_run');
    expect(jsonDecode(asked.last.body),
        {'profile': 'prof_me', 'game': 'spellstorm', 'key': 'new_run'});
  });

  test('hosts from before game buttons offer none', () async {
    final api = GameNightApi(Uri.parse('http://192.168.1.5:3000'),
        client: MockClient((_) async => http.Response('', 404)));
    expect(await LocalRoomControls(api, 'prof_me').actions(), isNull);
  });

  testWidgets('a button that ends the round asks first', (tester) async {
    final controls = FakeControls();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GameActionsSection(controls: controls))));
    await tester.pump();
    expect(find.text('Spellstorm'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('action-new_run')));
    await tester.pumpAndSettle();
    expect(find.text('Ends this run for everyone.'), findsOneWidget);
    expect(controls.pressed, isEmpty, reason: 'not before confirming');
    await tester.tap(find.byKey(const ValueKey('action-confirm')));
    await tester.pumpAndSettle();
    expect(controls.pressed, ['spellstorm/new_run']);
    expect(find.text('New run: sent to the game.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
