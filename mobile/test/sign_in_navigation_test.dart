import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_test.dart' show FakeCloud;

void main() {
  for (final entry in ['code', 'link', 'cold link']) {
    final viaLink = entry != 'code';
    testWidgets('sign in from a room $entry keeps the home route', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cloud = FakeCloud();
      final state =
          AppState(await SharedPreferences.getInstance(), cloud: CloudApi(client: cloud.client));
      final links = StreamController<Uri>();
      addTearDown(links.close);
      await tester.pumpWidget(GameNightApp(
          state: state,
          links: links.stream,
          initialLink: entry == 'cold link'
              ? Uri.parse('https://gamenight.ontola.io/join#room=ABC234')
              : null));
      if (entry == 'cold link') {
        await tester.pump();
      } else if (viaLink) {
        links.add(Uri.parse('https://gamenight.ontola.io/join#room=ABC234'));
      } else {
        await tester.enterText(find.byType(TextField).first, 'ABC234');
      }
      await tester.pumpAndSettle();
      expect(find.text('Email me a code'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'test@example.com');
      await tester.tap(find.text('Email me a code'));
      await tester.pumpAndSettle();
      if (viaLink) {
        links.add(Uri.parse('https://gamenight.ontola.io/auth/login#code=12345678'));
        links.add(Uri.parse('https://gamenight.ontola.io/auth/login#code=12345678'));
      } else {
        await tester.enterText(find.byType(TextField).last, '12345678');
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(state.inHostedRoom, isTrue);
      expect(cloud.calls.where((c) => c == 'POST /auth/email/verify'), hasLength(1));
      await tester.tap(find.text('Room'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for pickup in the lobby'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }
}
