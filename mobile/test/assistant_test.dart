import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/assistant.dart';
import 'package:gamenight/screens/assistant_screen.dart';
import 'package:gamenight/theme.dart';
import 'package:gamenight/voice_feedback.dart';

Map<String, dynamic> ready(
        {bool local = true, List<Object> requests = const []}) =>
    {
      'provider_configured': true,
      'local_model': local,
      'can_fund': true,
      'credits': {'available': 100},
      'funding': {'remaining': 50},
      'requests': requests,
      'controls': {
        'game': 'frog-fighter',
        'instance': 'frog-1',
        'revision': 2,
        'can_undo': true,
        'settings': <String, Object>{}
      }
    };
CloudApi api(Future<http.Response> Function(http.Request) handler) =>
    CloudApi(client: MockClient(handler), token: 'test-token');
http.Response json(Object body) => http.Response(jsonEncode(body), 200);

class NoSpeech implements SpeechInput {
  @override
  Future<bool> initialize(
          {required void Function(String) onStatus,
          required void Function(String) onError}) async =>
      false;
  @override
  Future<void> listen(void Function(String, bool) onText,
      {void Function(double)? onSoundLevel}) async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'paid request requires a quote and second explicit send; same id on retry',
      () async {
    final sent = <Map<String, dynamic>>[];
    final quotes = <String>[];
    var fail = true;
    final a = Assistant(api((r) async {
      expect(r.headers['authorization'], 'Bearer test-token');
      if (r.method == 'GET') return json(ready(local: false));
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.url.path.endsWith('/quote')) {
        quotes.add(body['request_id']);
        return json({'maximum_credits': 3});
      }
      sent.add(body);
      if (fail) {
        fail = false;
        return http.Response('', 503);
      }
      return json({'id': body['request_id']});
    }));
    addTearDown(a.dispose);
    await a.refresh();
    a.setDraft('Make jumping higher');
    await a.send();
    expect(a.quote, 3);
    expect(sent, isEmpty);
    await a.send();
    expect(a.error, isNotNull);
    expect(a.draft, 'Make jumping higher');
    await a.send();
    expect(sent.length, 2);
    expect(sent[0]['request_id'], sent[1]['request_id']);
    expect(sent[1]['request_id'], quotes.single);
    expect(sent[1]['max_credits'], 3);
    expect(a.draft, isEmpty);
    expect(a.waiting, isTrue);
  });
  test('local request waits for its own host receipt and shows failure',
      () async {
    String? id;
    var completed = false;
    final a = Assistant(api((r) async {
      if (r.method == 'POST') {
        id = jsonDecode(r.body)['request_id'];
        expect(jsonDecode(r.body)['max_credits'], 0);
        return json({});
      }
      return json(ready(requests: [
        if (id != null)
          {
            'id': id,
            'state': completed ? 'failed' : 'queued',
            'result': completed ? 'Game closed before the change.' : null
          }
      ]));
    }));
    addTearDown(a.dispose);
    await a.refresh();
    a.setDraft('Make this easier');
    await a.send();
    expect(a.waiting, isTrue);
    completed = true;
    await a.refresh();
    expect(a.waiting, isFalse);
    expect(a.notice, 'Game closed before the change.');
  });
  test('old room replies cannot replace current room state or quote', () async {
    final reply = Completer<http.Response>();
    final a = Assistant(api((r) => reply.future));
    addTearDown(a.dispose);
    final loading = a.refresh();
    a.reset();
    reply.complete(json(ready()));
    await loading;
    expect(a.status, isNull);
    expect(a.loading, isFalse);
  });
  test('editing or a changed game invalidates a paid estimate', () async {
    var instance = 'one';
    final a = Assistant(api((r) async => r.method == 'GET'
        ? json({
            ...ready(local: false),
            'controls': {
              'game': 'frog-fighter',
              'instance': instance,
              'revision': 1
            }
          })
        : json({'maximum_credits': 2})));
    addTearDown(a.dispose);
    await a.refresh();
    a.setDraft('Jump higher');
    await a.send();
    expect(a.quote, 2);
    a.setDraft('Jump lower');
    expect(a.quote, isNull);
    await a.send();
    instance = 'two';
    await a.refresh();
    expect(a.quote, isNull);
  });
  test('undo and configs use the active instance and revision', () async {
    final posts = <Map<String, dynamic>>[];
    final a = Assistant(api((r) async {
      if (r.method == 'GET') {
        return json(
            r.url.path.endsWith('/presets') ? {'presets': []} : ready());
      }
      posts.add(jsonDecode(r.body));
      return json({});
    }));
    addTearDown(a.dispose);
    await a.refresh();
    await a.savePreset('Moon jump');
    expect(posts.last['expected_revision'], 2);
    expect(posts.last['instance'], 'frog-1');
    await a.control('undo');
    expect(posts.last['command']['action'], 'undo');
    expect(posts.last['command']['expected_revision'], 2);
  });
  testWidgets(
      'native Assistant shows room results, mic failures and keeps draft',
      (tester) async {
    SharedPreferences.setMockInitialValues({'cloud_token': 'test-token'});
    final cloud = api((r) async {
      if (r.url.path.endsWith('/presets')) return json({'presets': []});
      if (r.method == 'POST') return http.Response('', 503);
      return json(ready());
    });
    final state = AppState(await SharedPreferences.getInstance(), cloud: cloud);
    final voice = VoiceFeedback(speech: NoSpeech());
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: AssistantScreen(state: state, voice: voice)));
    await tester.pumpAndSettle();
    expect(find.text('Frog Fighter'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('assistant-draft')), 'Make it easier');
    await tester.tap(find.byTooltip('Talk to Assistant'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Microphone or speech access is unavailable'),
        findsOneWidget);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('AI provider is not configured'), findsOneWidget);
    expect(find.text('Make it easier'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    voice.dispose();
  });
}
