import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gamenight/reports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('feedback persists offline and retries exactly the same id after restart', () async {
    final sent = <Map>[];
    final first = ReportService(prefs, client: MockClient((r) async {
      sent.add(jsonDecode(r.body) as Map);
      throw Exception('offline');
    }));
    await first.saveDraft('The next game never loaded.');
    expect(await first.submitFeedback(first.draft), false);
    expect(first.draft, '');
    first.close();
    final second = ReportService(prefs, client: MockClient((r) async {
      final body = jsonDecode(r.body) as Map;
      sent.add(body);
      return http.Response(jsonEncode({'id': body['id']}), 201);
    }));
    await second.flush();
    expect(sent.length, 2);
    expect(sent[0]['id'], sent[1]['id']);
    expect(jsonDecode(prefs.getString('report_outbox')!), isEmpty);
    second.close();
  });

  test('automatic errors exclude exception data, deduplicate and link to feedback', () async {
    final sent = <Map>[];
    final reports = ReportService(prefs,
        context: () => {'game': 'ballkickers'},
        client: MockClient((r) async {
          expect(r.headers.containsKey('authorization'), false);
          final body = jsonDecode(r.body) as Map;
          sent.add(body);
          return http.Response(jsonEncode({'id': body['id']}), 201);
        }));
    final error = Exception('Private name token=secret');
    reports.captureError(
        error, StackTrace.fromString('https://example.com/auth#code=secret test@example.com'));
    reports.captureError(error, StackTrace.current);
    await reports.flush();
    expect(sent.length, 1);
    expect(sent.first['text'], 'unhandled: _Exception');
    expect(sent.first['stack'], '[url] [email]');
    expect(sent.first['context']['game'], 'ballkickers');
    await reports.submitFeedback('It stopped.');
    expect(sent.length, 2);
    expect(sent.last['related_error'], sent.first['id']);
    reports.close();
  });

  test('success without matching receipt never discards a report', () async {
    final reports =
        ReportService(prefs, client: MockClient((r) async => http.Response('{"id":"wrong"}', 200)));
    expect(await reports.submitFeedback('Nothing happened'), false);
    expect(jsonDecode(prefs.getString('report_outbox')!), hasLength(1));
    reports.close();
  });

  test('queue bounds errors without evicting feedback and rejects empty feedback', () async {
    final reports = ReportService(prefs, client: MockClient((r) async => http.Response('', 503)));
    await expectLater(reports.submitFeedback('   '), throwsArgumentError);
    for (var i = 0; i < 60; i++) {
      await reports.submitFeedback('feedback $i');
    }
    await expectLater(reports.submitFeedback('keep my draft'), throwsStateError);
    expect(jsonDecode(prefs.getString('report_outbox')!), hasLength(60));
    reports.close();
  });
  test('game recipient is explicit and independent from playing game context', () async {
    final sent = <Map>[];
    final reports = ReportService(prefs,
        context: () => {'game': 'ballkickers'},
        client: MockClient((r) async {
          final body = jsonDecode(r.body) as Map;
          sent.add(body);
          return http.Response(jsonEncode({'id': body['id']}), 200);
        }));
    await reports.saveDraft('This needs work', game: 'frog-fighter');
    expect(reports.draftGame, 'frog-fighter');
    await reports.submitFeedback(reports.draft, game: reports.draftGame);
    expect(sent[0]['game'], 'frog-fighter');
    expect(sent[0]['context']['game'], 'ballkickers');
    expect(reports.draftGame, isNull);
    await reports.submitFeedback('The lobby froze');
    expect(sent[1].containsKey('game'), false);
    expect(sent[1]['context']['game'], 'ballkickers');
    reports.close();
  });
}
