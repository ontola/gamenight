import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// A small boundary so interruptions and partial speech can be tested without a mic.
abstract interface class SpeechInput {
  Future<bool> initialize({
    required void Function(String) onStatus,
    required void Function(String) onError,
  });
  Future<void> listen(void Function(String, bool) onText,
      {void Function(double)? onSoundLevel});
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
  Future<void> listen(void Function(String, bool) onText,
      {void Function(double)? onSoundLevel}) async {
    await _speech.listen(
      onResult: (result) => onText(result.recognizedWords, result.finalResult),
      onSoundLevelChange: onSoundLevel,
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
  String? errorCode;
  double soundLevel = 0;
  bool microphoneActive = false;
  bool finishing = false;
  bool _sessionOpen = false;
  bool _hasWords = false;
  Timer? _startupTimer;
  Timer? _silenceTimer;
  Timer? _endTimer;
  Timer? _limitTimer;

  void _clearTimers() {
    _startupTimer?.cancel();
    _silenceTimer?.cancel();
    _endTimer?.cancel();
    _limitTimer?.cancel();
  }

  void _completeSession() {
    if (!_sessionOpen) return;
    _sessionOpen = false;
    _clearTimers();
    listening = false;
    microphoneActive = false;
    finishing = false;
    soundLevel = 0;
    if (!_hasWords && error == null) {
      errorCode = 'no_words';
      error =
          'No speech was recognised. Try again, check your phone’s speech language, or type below.';
    }
    _finishWords();
    _changed();
  }

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
    errorCode = null;
    soundLevel = 0;
    microphoneActive = false;
    finishing = false;
    _hasWords = false;
    _clearTimers();
    _operations++;
    _changed();
    try {
      if (!_initialized) {
        _initialized = await _speech
            .initialize(
              onStatus: _status,
              onError: _error,
            )
            .timeout(const Duration(seconds: 20));
      }
      if (generation != _generation || _disposed) return;
      if (!_initialized) {
        errorCode = 'unavailable';
        error =
            'Microphone or speech access is unavailable. Allow access in your '
            'phone settings, or type your feedback below.';
        return;
      }
      listening = true;
      _sessionOpen = true;
      _startupTimer = Timer(const Duration(seconds: 8), () {
        if (_sessionOpen && !microphoneActive) _error('start_timeout');
      });
      _silenceTimer = Timer(const Duration(seconds: 20), () {
        if (_sessionOpen && !_hasWords) _error('no_words');
      });
      _limitTimer = Timer(const Duration(seconds: 65), () {
        if (_sessionOpen) unawaited(stop());
      });
      await _speech.listen((words, finalResult) {
        if (_disposed || generation != _generation || !_sessionOpen) return;
        if (words.trim().isNotEmpty) {
          _hasWords = true;
          _startupTimer?.cancel();
          _silenceTimer?.cancel();
          microphoneActive = true;
          text =
              [prefix, words.trim()].where((part) => part.isNotEmpty).join(' ');
        }
        if (finalResult) _completeSession();
        _changed();
      }, onSoundLevel: (level) {
        if (_disposed || generation != _generation || !_sessionOpen) return;
        microphoneActive = true;
        _startupTimer?.cancel();
        soundLevel = ((level + 2) / 12).clamp(0.0, 1.0);
        _changed();
      }).timeout(const Duration(seconds: 10));
      // A permission dialog, navigation, or background event may have cancelled
      // while the platform was starting. Do not leave a late microphone running.
      if (generation != _generation || _disposed) {
        await _speech.cancel().timeout(const Duration(seconds: 2));
      }
    } catch (_) {
      if (generation == _generation && !_disposed) {
        errorCode = 'start_failed';
        _sessionOpen = false;
        _clearTimers();
        microphoneActive = false;
        finishing = false;
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
    if (_disposed || !_sessionOpen) return;
    if (status == 'listening') {
      microphoneActive = true;
      _startupTimer?.cancel();
    } else if (status == 'done') {
      _completeSession();
    } else if (status == 'notListening') {
      finishing = true;
      // Android ends audio capture before delivering its final transcript.
      // Keep accepting that result, but never wait indefinitely for it.
      microphoneActive = false;
      soundLevel = 0;
      _endTimer?.cancel();
      _endTimer = Timer(const Duration(seconds: 2), _completeSession);
    }
    _changed();
  }

  void _error(String code) {
    if (_disposed || (!_sessionOpen && _initialized)) return;
    ++_generation;
    _sessionOpen = false;
    _clearTimers();
    _finishWords();
    listening = false;
    microphoneActive = false;
    finishing = false;
    soundLevel = 0;
    errorCode = code;
    error = switch (code) {
      'error_permission' ||
      'error_permission_denied' ||
      'error_not_allowed' ||
      'error_audio_permission' ||
      'error_speech_permission' =>
        'Microphone or speech access is off. Allow access in your phone settings, '
            'or type your feedback below.',
      'error_no_match' || 'error_speech_timeout' || 'no_words' => _hasWords
          ? 'Recording paused. Your words are saved below.'
          : 'No speech was recognised. Try again, check your phone’s speech language, or type below.',
      'start_timeout' =>
        'The microphone did not start. Check microphone access and your phone’s speech service, then try again.',
      'error_network' ||
      'error_network_timeout' ||
      'error_server' ||
      'error_server_disconnected' =>
        'Speech recognition could not connect. Check your internet connection, then try again.',
      'error_language_not_supported' ||
      'error_language_unavailable' =>
        'Your phone’s speech language is unavailable. Enable or download it in your phone settings, or type below.',
      'error_audio_error' =>
        'The microphone could not capture audio. Check microphone access, then try again.',
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
      await _speech.cancel().timeout(const Duration(seconds: 2));
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
        await _speech.stop().timeout(const Duration(seconds: 3));
        await completion.future
            .timeout(const Duration(seconds: 1), onTimeout: () {});
      } catch (_) {
        await _cancelQuietly();
      } finally {
        _completeSession();
        if (generation == _generation) ++_generation;
        if (identical(_finalWords, completion)) _finalWords = null;
        _operations--;
        _changed();
      }
    }
  }

  Future<void> cancel() async {
    _sessionOpen = false;
    _clearTimers();
    microphoneActive = false;
    finishing = false;
    soundLevel = 0;
    ++_generation;
    _finishWords();
    listening = false;
    _changed();
    await _cancelQuietly();
  }

  /// Editing an idle draft must not toggle the keyboard via native mic calls.
  void invalidateResults() {
    _sessionOpen = false;
    _clearTimers();
    ++_generation;
    _finishWords();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionOpen = false;
    _clearTimers();
    ++_generation;
    _finishWords();
    unawaited(_cancelQuietly());
    super.dispose();
  }
}
