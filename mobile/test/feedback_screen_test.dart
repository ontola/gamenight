import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/reports.dart';
import 'package:gamenight/screens/feedback_screen.dart';
import 'package:gamenight/theme.dart';
import 'package:gamenight/voice_feedback.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_feedback_test.dart' show FakeSpeech;

final _previewKey = GlobalKey();
final _previewDir = Platform.environment['FEEDBACK_PREVIEW_DIR'];

Future<void> _capture(WidgetTester tester, String name) async {
  if (_previewDir == null) return;
  await tester.pump();
  final boundary =
      _previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(_previewDir!).create(recursive: true);
    await File('$_previewDir/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _open(
    WidgetTester tester, ReportService reports, VoiceFeedback voice,
    {String? initialGame}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  var theme = gameNightTheme();
  // FilledButton's explicit weight otherwise inherits the test-only Ahem font.
  // Match the runtime's Roboto default when rendering review screenshots.
  if (_previewDir != null) {
    theme = theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
      style: theme.filledButtonTheme.style!.copyWith(
          textStyle: const WidgetStatePropertyAll(
              TextStyle(fontFamily: 'Roboto', fontWeight: FontWeight.w600))),
    ));
  }
  await tester.pumpWidget(RepaintBoundary(
      key: _previewKey,
      child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: FeedbackScreen(
              reports: reports, voice: voice, initialGame: initialGame))));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fonts = Platform.environment['FEEDBACK_PREVIEW_FONTS'];
    if (fonts != null) {
      final loader = FontLoader('Roboto');
      for (final weight in ['Regular', 'Bold']) {
        loader.addFont(File('$fonts/Roboto-$weight.ttf')
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)));
      }
      await loader.load();
      final defaultFont = FontLoader('Ahem')
        ..addFont(File('$fonts/Roboto-Regular.ttf')
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)));
      await defaultFont.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });

  testWidgets(
      'catalog target defaults correctly and cannot silently retarget a saved draft',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final reports = ReportService(await SharedPreferences.getInstance());
    final voice = VoiceFeedback(speech: FakeSpeech());
    addTearDown(() {
      reports.close();
      voice.dispose();
      tester.view.reset();
    });
    await _open(tester, reports, voice, initialGame: 'pocket-aces');
    expect(find.text('Sent to the developer of Pocket Aces.'), findsOneWidget);
    await _tap(tester, find.text('GameNight'));
    await tester.enterText(find.byKey(const ValueKey('feedback-draft')),
        'Please keep this feedback for GameNight.');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await _open(tester, reports, voice, initialGame: 'pocket-aces');
    expect(find.text('Sent to the GameNight team.'), findsOneWidget);
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('feedback-send')), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'narrow phone has no overflow');
  });

  testWidgets(
      'talk, pause, continue, edit, then send only reviewed text to selected game',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <Map<String, dynamic>>[];
    final reports = ReportService(await SharedPreferences.getInstance(),
        context: () => {'game': 'pocket-aces'},
        client: MockClient((request) async {
          final data = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(data);
          return http.Response(jsonEncode({'id': data['id']}), 200);
        }));
    final speech = FakeSpeech();
    final voice = VoiceFeedback(speech: speech);
    addTearDown(() {
      reports.close();
      voice.dispose();
      tester.view.reset();
    });
    await _open(tester, reports, voice);
    expect(find.text('Sent to the developer of Pocket Aces.'), findsOneWidget);
    await _capture(tester, 'feedback-start');
    await _tap(tester, find.byKey(const ValueKey('feedback-record')));
    speech.result!('The cards are easy to read.');
    await tester.pump();
    expect(find.text('Listening…'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('feedback-send')))
            .onPressed,
        isNull);
    await _capture(tester, 'feedback-listening');
    speech.status!('done');
    await tester.pumpAndSettle();
    expect(find.text('Continue recording'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('feedback-record')));
    speech.result!('Please add a larger ready button.');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('feedback-record')));
    await tester.enterText(find.byKey(const ValueKey('feedback-draft')),
        'The cards look great. Could the ready button be larger?');
    await tester.pumpAndSettle();
    expect(reports.draft,
        'The cards look great. Could the ready button be larger?');
    expect(reports.draftGame, 'pocket-aces');
    await tester.ensureVisible(find.byKey(const ValueKey('feedback-send')));
    await tester.pumpAndSettle();
    await _capture(tester, 'feedback-review');
    expect(requests, isEmpty,
        reason: 'nothing sends before explicit review/send');
    await _tap(tester, find.byKey(const ValueKey('feedback-send')));
    expect(requests.single['text'],
        'The cards look great. Could the ready button be larger?');
    expect(requests.single['game'], 'pocket-aces');
    expect(requests.single.containsKey('audio'), false);
    expect(reports.draft, isEmpty);
    expect(find.text('Thanks for the feedback'), findsOneWidget);
    await _capture(tester, 'feedback-sent');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'permission denied leaves keyboard available and offline feedback queued for GameNight',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    Map<String, dynamic>? submitted;
    final reports = ReportService(await SharedPreferences.getInstance(),
        context: () => {'game': 'pocket-aces'},
        client: MockClient((request) async {
          submitted = jsonDecode(request.body);
          return http.Response('Unavailable', 503);
        }));
    final speech = FakeSpeech()..available = false;
    final voice = VoiceFeedback(speech: speech);
    addTearDown(() {
      reports.close();
      voice.dispose();
      tester.view.reset();
    });
    await _open(tester, reports, voice);
    await _tap(tester, find.text('GameNight'));
    await _tap(tester, find.byKey(const ValueKey('feedback-record')));
    expect(find.textContaining('Allow access in your phone settings'),
        findsOneWidget);
    await _tap(tester, find.text('Use keyboard'));
    await tester.enterText(find.byKey(const ValueKey('feedback-draft')),
        'Joining the room took a few tries.');
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('feedback-send')));
    expect(submitted!.containsKey('game'), false,
        reason: 'GameNight target never sends to developer');
    expect(find.text('Saved. We’ll send it soon.'), findsOneWidget);
    await _capture(tester, 'feedback-queued');
    expect(reports.draft, isEmpty);
  });

  testWidgets(
      'background stops microphone and leaving restores edited draft and target',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final reports = ReportService(await SharedPreferences.getInstance(),
        context: () => {'game': 'pocket-aces'});
    final speech = FakeSpeech();
    final voice = VoiceFeedback(speech: speech);
    addTearDown(() {
      reports.close();
      voice.dispose();
      tester.view.reset();
    });
    await _open(tester, reports, voice);
    await _tap(tester, find.text('GameNight'));
    await _tap(tester, find.byKey(const ValueKey('feedback-record')));
    speech.result!('Please remember my draft.');
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(voice.listening, false);
    expect(speech.cancels, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await _open(tester, reports, voice);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('feedback-draft')))
            .controller!
            .text,
        'Please remember my draft.');
    expect(find.text('Sent to the GameNight team.'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('feedback-record')));
    expect(speech.initializations, 1);
    speech.error!('error_busy');
    await tester.pumpAndSettle();
    expect(find.textContaining('microphone is busy'), findsOneWidget,
        reason: 'app-owned callbacks still reach reopened screen');
    expect(tester.takeException(), isNull);
  });
}
