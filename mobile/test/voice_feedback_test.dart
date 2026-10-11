import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/voice_feedback.dart';

class FakeSpeech implements SpeechInput {
  void Function(String)? status;
  void Function(String)? error;
  void Function(String)? result;
  void Function(String)? finalResult;
  String? wordsOnStop;
  bool available = true;
  bool failListen = false;
  int initializations = 0;
  int listens = 0;
  int stops = 0;
  int cancels = 0;
  Completer<bool>? initialization;

  @override
  Future<bool> initialize(
      {required void Function(String) onStatus,
      required void Function(String) onError}) async {
    initializations++;
    status = onStatus;
    error = onError;
    return initialization == null ? available : initialization!.future;
  }

  @override
  Future<void> listen(void Function(String, bool) onText) async {
    listens++;
    if (failListen) throw StateError('native service unavailable');
    result = (words) => onText(words, false);
    finalResult = (words) => onText(words, true);
  }

  @override
  Future<void> stop() async {
    stops++;
    if (wordsOnStop != null) finalResult?.call(wordsOnStop!);
    status?.call('done');
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }
}

void main() {
  test('stop keeps final words but ignores results from a stopped session',
      () async {
    final speech = FakeSpeech()..wordsOnStop = 'The cards look great';
    final voice = VoiceFeedback(speech: speech);
    await voice.start('');
    speech.result!('The cards');
    final late = speech.result!;
    await voice.stop();
    expect(voice.text, 'The cards look great');
    await voice.start(voice.text);
    late('stale result');
    expect(voice.text, 'The cards look great');
    voice.dispose();
  });
  test(
      'partials replace each other, resumed recording appends to reviewed draft',
      () async {
    final speech = FakeSpeech();
    final voice = VoiceFeedback(speech: speech);
    await voice.start('The controls');
    speech.result!('feel');
    speech.result!('feel great');
    expect(voice.text, 'The controls feel great');
    speech.status!('done');
    expect(voice.listening, false);
    await voice.start('The controls feel good.');
    speech.result!('More levels please.');
    expect(voice.text, 'The controls feel good. More levels please.');
    expect(speech.initializations, 1,
        reason: 'callbacks have one app-lifetime owner');
    await voice.stop();
    expect(speech.stops, 1);
    voice.dispose();
  });

  test('cancel invalidates late results and keeps partial text', () async {
    final speech = FakeSpeech();
    final voice = VoiceFeedback(speech: speech);
    await voice.start('');
    speech.result!('A useful draft');
    final late = speech.result!;
    await voice.cancel();
    late('A result from an abandoned session');
    expect(voice.text, 'A useful draft');
    expect(voice.listening, false);
    expect(voice.busy, false);
    voice.dispose();
  });

  test('background during initialization never opens a late microphone',
      () async {
    final speech = FakeSpeech()..initialization = Completer<bool>();
    final voice = VoiceFeedback(speech: speech);
    final start = voice.start('Saved draft');
    await voice.cancel();
    expect(voice.busy, true,
        reason: 'do not start a second initialization concurrently');
    speech.initialization!.complete(true);
    await start;
    expect(speech.listens, 0);
    expect(voice.busy, false);
    expect(voice.text, 'Saved draft');
    voice.dispose();
  });

  test('permission denial and busy errors release recording and preserve draft',
      () async {
    final speech = FakeSpeech()..available = false;
    final voice = VoiceFeedback(speech: speech);
    await voice.start('Keep this');
    expect(voice.error, contains('phone settings'));
    expect(voice.busy, false);
    expect(voice.listening, false);
    speech.available = true;
    await voice.start('Keep this');
    speech.error!('error_busy');
    await Future<void>.delayed(Duration.zero);
    expect(voice.error, contains('microphone is busy'));
    expect(voice.listening, false);
    expect(voice.text, 'Keep this');
    expect(speech.cancels, greaterThan(0));
    voice.dispose();
  });

  test('a failed native start allows retry instead of leaving busy stuck',
      () async {
    final speech = FakeSpeech()..failListen = true;
    final voice = VoiceFeedback(speech: speech);
    await voice.start('Saved draft');
    expect(voice.busy, false);
    expect(voice.error, contains('could not start'));
    speech.failListen = false;
    await voice.start(voice.text);
    expect(voice.listening, true);
    expect(speech.initializations, 1);
    voice.dispose();
  });
}
