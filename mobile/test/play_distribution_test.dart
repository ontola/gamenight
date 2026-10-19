import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/api.dart';
import 'package:gamenight/app_update.dart';
import 'package:gamenight/apps.dart';
import 'package:gamenight/screens/game_screen.dart';
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Play distribution', () {
    test(
      'never checks the APK feed or requests package installation',
      () async {
        var contacted = false;
        final client = MockClient((_) async {
          contacted = true;
          throw StateError('APK feed contacted');
        });
        expect(await AppUpdate.newer(build: 10, client: client), isNull);
        expect(contacted, isFalse);
        expect(await Apps.canInstall(), isFalse);
        expect(await Apps.silentSelfUpdate(), isFalse);
        await expectLater(Apps.allowInstalls(), throwsUnsupportedError);
        await expectLater(
          Apps.install(Uri.parse('https://example.test/game.apk'), 'test.game'),
          throwsUnsupportedError,
        );
        client.close();
      },
    );

    testWidgets(
      'keeps opening installed companions but offers no APK installs',
      (tester) async {
        const channel = MethodChannel('gamenight/apps');
        var installed = false;
        final calls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call.method);
            if (call.method == 'installed') return installed ? '1.0' : null;
            if (call.method == 'open') return true;
            throw StateError('Unexpected platform call: ${call.method}');
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        Widget card() => MaterialApp(
              home: Scaffold(
                body: AppCard(
                  key: UniqueKey(),
                  app: const CompanionApp(
                    name: 'Test companion',
                    android: 'test.game',
                  ),
                  download: Uri.parse('https://example.test/game.apk'),
                ),
              ),
            );
        await tester.pumpWidget(card());
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Install'),
              )
              .onPressed,
          isNull,
        );
        installed = true;
        await tester.pumpWidget(card());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open'));
        await tester.pump();
        expect(calls, ['installed', 'installed', 'open']);
        expect(find.text('Update from the GameNight computer'), findsNothing);
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }, skip: !Apps.playStore);
}
