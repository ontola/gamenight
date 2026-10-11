import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// A small boundary so interruptions and partial speech can be tested without a mic.
abstract interface class SpeechInput {
  Future<bool> initialize({
    required void Function(String) onStatus,
    required void Function(String) onError,
  });
  Future<void> listen(void Function(String, bool) onText);
  Future<void> stop();
  Future<void> cancel();
}

class _DeviceSpeech implements SpeechInput {
  final _speech = stt.SpeechToText();

  @override
  Future<bool> initialize({
    required void Function(String) onStatus,
    required void Function(String) onError,
  }) =>
      _speech.initialize(
        onStatus: onStatus,
        onError: (error) => onError(error.errorMsg),
        options: [stt.SpeechToText.androidNoBluetooth],
      );

  @override
  Future<void> listen(void Function(String, bool) onText) async {
    await _speech.listen(
      onResult: (result) => onText(result.recognizedWords, result.finalResult),
      listenOptions: stt.SpeechListenOptions(
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
        cancelOnError: true,
        listenMode: stt.ListenMode.dictation,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();
  @override
  Future<void> cancel() => _speech.cancel();
}

/// The native plugin keeps its first initialization callbacks for the entire app.
/// Keep their owner alive too; screens only attach and detach listeners.
class VoiceFeedback extends ChangeNotifier {
  VoiceFeedback({required SpeechInput speech}) : _speech = speech;
  static final instance = VoiceFeedback(speech: _DeviceSpeech());

  final SpeechInput _speech;
  bool _initialized = false;
  bool _disposed = false;
  int _generation = 0;
  bool listening = false;
  int _operations = 0;
  bool get busy => _operations > 0;
  String text = '';
  String? error;
  Completer<void>? _finalWords;

  void _finishWords() {
    if (_finalWords case final completion? when !completion.isCompleted) {
      completion.complete();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(String draft) async {
    if (busy || listening || _disposed) return;
    final generation = ++_generation;
    final prefix = draft.trimRight();
    text = draft;
    error = null;
    _operations++;
    _changed();
    try {
      if (!_initialized) {
        _initialized = await _speech.initialize(
          onStatus: _status,
          onError: _error,
        );
      }
      if (generation != _generation || _disposed) return;
      if (!_initialized) {
        error =
            'Microphone or speech access is unavailable. Allow access in your '
            'phone settings, or type your feedback below.';
        return;
      }
      listening = true;
      await _speech.listen((words, finalResult) {
        if (_disposed || generation != _generation) return;
        text =
            [prefix, words.trim()].where((part) => part.isNotEmpty).join(' ');
        if (finalResult) _finishWords();
        _changed();
      });
      // A permission dialog, navigation, or background event may have cancelled
      // while the platform was starting. Do not leave a late microphone running.
      if (generation != _generation || _disposed) await _speech.cancel();
    } catch (_) {
      if (generation == _generation && !_disposed) {
        error =
            'Recording could not start. Try again, or type your feedback below.';
        listening = false;
        ++_generation;
        await _cancelQuietly();
      }
    } finally {
      _operations--;
      _changed();
    }
  }

  void _status(String status) {
    if (_disposed) return;
    if (status == 'done' || status == 'notListening') {
      listening = false;
      if (status == 'done') _finishWords();
      _changed();
    }
  }

  void _error(String code) {
    if (_disposed) return;
    ++_generation;
    _finishWords();
    listening = false;
    error = switch (code) {
      'error_permission' ||
      'error_permission_denied' ||
      'error_not_allowed' ||
      'error_audio_permission' ||
      'error_speech_permission' =>
        'Microphone or speech access is off. Allow access in your phone settings, '
            'or type your feedback below.',
      'error_no_match' ||
      'error_speech_timeout' =>
        'Recording paused. Continue recording, or edit what you have below.',
      'error_busy' =>
        'The microphone is busy. Close other recording apps, or type below.',
      _ => 'Recording stopped. Your draft is safe. Try again, or type below.',
    };
    unawaited(_cancelQuietly());
    _changed();
  }

  Future<void> _cancelQuietly() async {
    _operations++;
    try {
      await _speech.cancel();
    } catch (_) {/* Keep the draft available. */} finally {
      _operations--;
      _changed();
    }
  }

  /// Stop the mic and briefly accept final words before allowing edits.
  Future<void> stop() async {
    final generation = _generation;
    final active = listening || busy;
    listening = false;
    _changed();
    if (active) {
      final completion = _finalWords = Completer<void>();
      _operations++;
      _changed();
      try {
        await _speech.stop();
        await completion.future
            .timeout(const Duration(seconds: 1), onTimeout: () {});
      } catch (_) {
        await _cancelQuietly();
      } finally {
        if (generation == _generation) ++_generation;
        if (identical(_finalWords, completion)) _finalWords = null;
        _operations--;
        _changed();
      }
    }
  }

  Future<void> cancel() async {
    ++_generation;
    _finishWords();
    listening = false;
    _changed();
    await _cancelQuietly();
  }

  /// Editing an idle draft must not toggle the keyboard via native mic calls.
  void invalidateResults() {
    ++_generation;
    _finishWords();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _finishWords();
    unawaited(_cancelQuietly());
    super.dispose();
  }
}
