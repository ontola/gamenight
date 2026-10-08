import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/avatar.dart';
import 'package:gamenight/character.dart';
import 'package:gamenight/main.dart';
import 'package:gamenight/screens/face_editor_screen.dart';
import 'package:gamenight/screens/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppState> _state([Map<String, Object> prefs = const {}]) async {
  SharedPreferences.setMockInitialValues(prefs);
  return AppState(await SharedPreferences.getInstance());
}

FaceCanvasPainter _canvasPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(
        find.descendant(of: find.byType(FaceEditorScreen), matching: find.byType(CustomPaint)))
    .map((p) => p.painter)
    .whereType<FaceCanvasPainter>()
    .single;

/// Paints [painter] at one device pixel per grid cell and returns RGBA bytes.
Future<Uint8List> _render(FaceCanvasPainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(48, 48));
  final image = await recorder.endRecording().toImage(48, 48);
  return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
}

List<int> _pixel(Uint8List rgba, int x, int y) {
  final i = (y * 48 + x) * 4;
  return rgba.sublist(i, i + 4);
}

void main() {
  // Decode the bundled body on the real clock, before any widget test caches it.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(await CharacterSprite.bundled(), isNotNull);
  });

  testWidgets('the You tab opens a full-screen editor and Done returns', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final state = await _state();
    await tester.pumpWidget(GameNightApp(state: state));
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Edit face'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit face'));
    await tester.pumpAndSettle();
    expect(find.byType(FaceEditorScreen), findsOneWidget);
    // The editor covers the tabs and the canvas spans the screen width.
    expect(find.byType(NavigationBar).hitTestable(), findsNothing);
    final canvas = tester.getSize(find.byKey(const ValueKey('face-canvas')));
    expect(canvas.width, greaterThan(330));
    expect(canvas.width, canvas.height);
    for (final label in ['Draw', 'Erase', 'Fill', 'Undo', 'Clear', 'Random']) {
      expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
    }
    expect(find.text('Body guide').hitTestable(), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(FaceEditorScreen), findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);
    state.dispose();
  });

  testWidgets('drawing in the editor saves the face', (tester) async {
    final state = await _state();
    await tester.pumpWidget(MaterialApp(home: FaceEditorScreen(state: state)));
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(state.face.every((c) => c == null), isTrue);

    final canvas = find.byKey(const ValueKey('face-canvas'));
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(2, 2));
    await tester.pump();
    expect(state.face[0], drawPalette.first);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(state.face[0], isNull);
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
  });

  testWidgets('the body guide chip toggles the guide and is remembered', (tester) async {
    final state = await _state();
    await tester.pumpWidget(MaterialApp(home: FaceEditorScreen(state: state)));
    expect(_canvasPainter(tester).guide, isTrue);

    await tester.tap(find.text('Body guide'));
    await tester.pump();
    expect(_canvasPainter(tester).guide, isFalse);
    expect(state.prefs.getBool(guidePref), isFalse);

    await tester.tap(find.text('Body guide'));
    await tester.pump();
    expect(_canvasPainter(tester).guide, isTrue);
    expect(state.prefs.getBool(guidePref), isTrue);
    state.dispose();
  });

  testWidgets('the body guide shows without joining a GameNight', (tester) async {
    final state = await _state();
    // Tinting the bundled body happens off the fake clock.
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: FaceEditorScreen(state: state)));
      for (var i = 0; i < 50 && _canvasPainter(tester).body == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    expect(_canvasPainter(tester).body, isNotNull);
    state.dispose();
  });

  test('the guide visibly changes the canvas', () async {
    final atlas = (await CharacterSprite.bundled())!;
    final body = await CharacterSprite.tint(atlas, '#ff0000', '#f5e9be');
    FaceCanvasPainter painter(bool guide) => FaceCanvasPainter(
        grid: emptyFace(), skin: const Color(0xFFF5E9BE), body: body, guide: guide, revision: 0);
    final on = await _render(painter(true)), off = await _render(painter(false));

    // Shoulders from the body, in the clothing colour.
    final shoulder = _pixel(on, 20, 44);
    expect(shoulder[0], greaterThan(shoulder[1] + 40));
    expect(_pixel(off, 20, 44), isNot(shoulder));
    // The eye marks and the solid round head.
    expect(_pixel(on, 24, 26), isNot(_pixel(off, 24, 26)));
    expect(_pixel(on, 24, 20), isNot(_pixel(off, 24, 20)));
  });
}
