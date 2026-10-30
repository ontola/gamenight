import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/room_controls.dart';
import 'package:gamenight/screens/settings_panel.dart';
import 'package:gamenight/theme.dart';
import 'package:gamenight/widgets/number_setting.dart';

class Controls extends RoomControls {
  @override
  Object get target => this;
  GameSettings current;
  final writes = <Map<String, Object>>[];
  Controls(this.current);

  @override
  Future<GameSettings?> settings({String? game}) => Future.value(current);

  @override
  Future<GameSettings?> applySettings(GameSettings current,
      {Map<String, Object> values = const {},
      SettingsAction action = SettingsAction.set}) async {
    writes.add(Map.of(values));
    this.current = GameSettings(
        game: current.game,
        instance: current.instance,
        revision: current.revision + 1,
        canUndo: true,
        settings: [
          for (final s in current.settings)
            Setting(
                key: s.key,
                label: s.label,
                kind: s.kind,
                value: values[s.key] ?? s.value,
                description: s.description,
                min: s.min,
                max: s.max,
                options: s.options),
        ]);
    return this.current;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Growing Guns as it declares itself.
GameSettings growingGuns() => GameSettings(
        game: 'growing-guns',
        instance: 'session',
        revision: 1,
        canUndo: false,
        settings: [
          const Setting(
              key: 'next_modifier',
              label: 'Next round',
              kind: SettingKind.choice,
              value: 'Random',
              description:
                  'A modifier for the next round only. Random rolls as usual.',
              options: [
                'Random',
                'None',
                'Low gravity',
                'Fog',
                'Supply storm',
                'Sudden death',
                'Headshots only',
                'Boom boom',
                'Brrrrt',
                'Gun swap',
                'Sniper fight',
                'Air strikes',
                'Ion cannon',
                'Blackout',
              ]),
          const Setting(
              key: 'rounds_to_win',
              label: 'Rounds to win (next match)',
              kind: SettingKind.number,
              value: 10,
              min: 1,
              max: 30),
          const Setting(
              key: 'gravity',
              label: 'Gravity % (next round)',
              kind: SettingKind.number,
              value: 100,
              min: 25,
              max: 175),
          const Setting(
              key: 'knob.damage',
              label: 'Damage % (live)',
              kind: SettingKind.number,
              value: 100,
              min: 25,
              max: 300),
        ]);

final preview = GlobalKey();

Future<Controls> show(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controls = Controls(growingGuns());
  await tester.pumpWidget(RepaintBoundary(
      key: preview,
      child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: gameNightTheme(),
          home: Scaffold(
              appBar: AppBar(title: const Text('Growing Guns')),
              body: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: SettingsSection(
                      controls: controls, title: 'Growing Guns'))))));
  await tester.pumpAndSettle();
  return controls;
}

Future<void> capture(WidgetTester tester, String name) async {
  final folder = Platform.environment['SETTINGS_PREVIEW_DIR'];
  if (folder == null) return;
  final boundary =
      preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(folder).create(recursive: true);
    await File('$folder/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

Finder row(String key) => find.byKey(ValueKey('setting-$key'));

void main() {
  setUpAll(() async {
    if (Platform.environment['SETTINGS_PREVIEW_DIR'] == null) return;
    final outfit = FontLoader('Outfit');
    for (final w in [400, 500, 600, 700, 800]) {
      outfit.addFont(rootBundle.load('assets/fonts/Outfit-$w.ttf'));
    }
    await outfit.load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });

  testWidgets('dragging the slider sends one value when let go',
      (tester) async {
    final controls = await show(tester);
    await capture(tester, 'gg-settings');
    final slider = find.descendant(
        of: row('knob.damage'),
        matching: find.byKey(const ValueKey('number-slider')));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(controls.writes, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controls.writes.length, 1);
    final sent = controls.writes.single['knob.damage'] as int;
    expect(sent, greaterThan(100));
    expect(sent % 5, 0);
  });

  testWidgets('tapping the value lets you type one', (tester) async {
    final controls = await show(tester);
    await tester.tap(find.descendant(
        of: row('gravity'),
        matching: find.byKey(const ValueKey('number-value'))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('number-field')), '400');
    await tester.tap(find.byKey(const ValueKey('number-set')));
    await tester.pumpAndSettle();
    expect(find.text('Choose 25 to 175.'), findsOneWidget);
    expect(controls.writes, isEmpty);
    await tester.enterText(find.byKey(const ValueKey('number-field')), '137');
    await tester.pump();
    await capture(tester, 'gg-type');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(controls.writes, [
      {'gravity': 137}
    ]);
    // A wide range nudges back onto the fives.
    await tester.tap(find.byTooltip('More Gravity % (next round)'));
    await tester.pumpAndSettle();
    expect(controls.writes.last, {'gravity': 140});
  });

  testWidgets('one tap picks the next round', (tester) async {
    final controls = await show(tester);
    await tester.tap(find.text('Blackout'));
    await tester.pumpAndSettle();
    expect(controls.writes, [
      {'next_modifier': 'Blackout'}
    ]);
    await capture(tester, 'gg-blackout');
  });

  test('wide ranges step in fives', () {
    expect(NumberSetting.stepFor(1, 30), 1);
    expect(NumberSetting.stepFor(25, 300), 5);
    expect(NumberSetting.stepFor(null, 300), 1);
  });
}
