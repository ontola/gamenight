import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/api.dart';
import 'package:gamenight/screens/game_screen.dart';

void main() {
  test('a phone screen may be a native app without a page', () {
    final c = Companion.fromJson({
      'game': 'voice-and-will',
      'title': 'The Voice and the Will',
      'app': {
        'name': 'The Voice and the Will',
        'android': 'io.ontola.godgame',
        'download': '/play/voice-and-will/god.apk',
      },
    })!;
    expect(c.url, isNull);
    expect(c.app!.android, 'io.ontola.godgame');
    final api = GameNightApi(Uri.parse('http://10.0.0.2:7913/'));
    expect(api.resolve(c.app!.download!).toString(),
        'http://10.0.0.2:7913/play/voice-and-will/god.apk');
    expect(api.resolve('https://example.com/app').toString(), 'https://example.com/app');
    expect(Companion.fromJson({'game': 'x'}), isNull);
  });

  testWidgets('GameNight installs the app, then opens it', (tester) async {
    const channel = MethodChannel('gamenight/apps');
    final calls = <String>[];
    String? version;
    var allowed = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'installed':
          return version;
        case 'canInstall':
          return allowed;
        case 'install':
          expect(call.arguments['url'], 'http://10.0.0.2:7913/play/vw/god.apk');
          version = '1.0';
          return null;
        case 'status':
          return version == null ? null : 'done';
        case 'open':
          return true;
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppCard(
          app: const CompanionApp(name: 'God', android: 'io.ontola.godgame'),
          download: Uri.parse('http://10.0.0.2:7913/play/vw/god.apk'),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Install'));
    await tester.pump();
    expect(calls, contains('allowInstalls'), reason: 'first ask Android to allow installs');

    allowed = true;
    await tester.tap(find.text('Install'));
    await tester.pump();
    expect(calls, contains('install'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.tap(find.text('Open'));
    expect(calls.last, 'open');
    await tester.pumpWidget(const SizedBox());
  });
}
