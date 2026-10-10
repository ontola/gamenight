import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/app_update.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  MockClient feed(String body, [int status = 200]) => MockClient((request) async {
        expect(request.url, AppUpdate.feed);
        return http.Response(body, status);
      });

  test('only a higher published build is an update', () async {
    expect(await AppUpdate.newer(build: 10, client: feed('{"build":12}')), 12);
    expect(await AppUpdate.newer(build: 12, client: feed('{"build":12}')), isNull);
    expect(await AppUpdate.newer(build: 13, client: feed('{"build":12}')), isNull);
    expect(await AppUpdate.newer(build: 10, client: feed('missing', 404)), isNull);
    expect(await AppUpdate.newer(build: 10, client: feed('not json')), isNull);
  });

  test('local builds never offer updates', () async {
    expect(await AppUpdate.newer(build: 0, client: feed('{"build":99}')), isNull);
    expect(appBuild, 0);
  });

  testWidgets('the banner installs the published APK', (tester) async {
    const channel = MethodChannel('gamenight/apps');
    final installs = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'canInstall':
          return true;
        case 'install':
          installs.add(call.arguments);
          return null;
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: UpdateBanner(check: () async => 12))));
    await tester.pump();
    expect(find.text('A new version of GameNight is ready.'), findsOneWidget);
    await tester.tap(find.text('Update'));
    await tester.pump();
    expect(installs, [
      {'url': AppUpdate.apk.toString(), 'package': 'io.ontola.gamenight'}
    ]);
    expect(find.textContaining('Android asks you to confirm'), findsOneWidget);
  });

  testWidgets('Later hides the banner and no update hides it too', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: UpdateBanner(check: () async => 12))));
    await tester.pump();
    await tester.tap(find.text('Later'));
    await tester.pump();
    expect(find.text('A new version of GameNight is ready.'), findsNothing);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: UpdateBanner(key: UniqueKey(), check: () async => null))));
    await tester.pump();
    expect(find.byType(TextButton), findsNothing);
  });
}
