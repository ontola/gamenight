import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/room_controls.dart';
import 'package:gamenight/screens/settings_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

PlayerSettings mine(int sensitivity, String character) => PlayerSettings(
      game: 'shooter',
      title: 'Shooter',
      settings: [
        Setting(
            key: 'sensitivity',
            label: 'Sensitivity %',
            kind: SettingKind.number,
            value: sensitivity,
            min: 40,
            max: 250),
        Setting(
            key: 'character',
            label: 'Character',
            kind: SettingKind.choice,
            value: character,
            options: const ['frog', 'cat']),
      ],
    );

class FakeControls extends RoomControls {
  @override
  Object get target => this;
  PlayerSettings current = mine(100, 'frog');
  final writes = <(String, Object)>[];

  @override
  Future<PlayerSettings?> playerSettings({String? game}) async => current;

  @override
  Future<PlayerSettings?> setPlayerSetting(
      String game, String key, Object value) async {
    writes.add((key, value));
    current = mine(
        key == 'sensitivity'
            ? value as int
            : current.settings.first.value as int,
        key == 'character'
            ? value as String
            : current.settings[1].value as String);
    return current;
  }

  // The rest of the room is not part of these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> pump(
    WidgetTester tester, FakeControls controls, SharedPreferences prefs,
    {bool signedIn = false}) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: MySettingsSection(
              controls: controls,
              store: PhoneSettingsStore(prefs),
              signedIn: signedIn))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('changes are the player\'s own and remembered on the phone',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controls = FakeControls();
    await pump(tester, controls, prefs);
    expect(find.text('My settings in Shooter'), findsOneWidget);
    expect(controls.writes, isEmpty);
    await tester.tap(find.byTooltip('More Sensitivity %'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cat'));
    await tester.pumpAndSettle();
    expect(controls.writes, [('sensitivity', 105), ('character', 'cat')]);
    final saved = jsonDecode(prefs.getString('my_game_settings')!);
    expect(saved['shooter'], {'sensitivity': 105, 'character': 'cat'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a phone that is not signed in hands its values to a new room',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'my_game_settings': jsonEncode({
        'shooter': {'sensitivity': 180, 'character': 'cat'}
      })
    });
    final prefs = await SharedPreferences.getInstance();
    final controls = FakeControls();
    await pump(tester, controls, prefs);
    expect(controls.writes, [('sensitivity', 180), ('character', 'cat')]);
    expect(find.text('180'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('signed in, the profile wins over the phone', (tester) async {
    SharedPreferences.setMockInitialValues({
      'my_game_settings': jsonEncode({
        'shooter': {'sensitivity': 180}
      })
    });
    final prefs = await SharedPreferences.getInstance();
    final controls = FakeControls();
    await pump(tester, controls, prefs, signedIn: true);
    expect(controls.writes, isEmpty);
    expect(
        jsonDecode(prefs.getString('my_game_settings')!)['shooter']
            ['sensitivity'],
        100);
    await tester.pumpWidget(const SizedBox());
  });
}
