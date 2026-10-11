import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_update.dart';
import 'link.dart';

/// Feedback and app errors share a durable outbox and the private team inbox.
/// No account, room code, credentials, raw audio or HTTP bodies are collected.
class ReportService {
  final SharedPreferences prefs;
  final http.Client _client;
  final Uri endpoint;
  final Map<String, String> Function()? context;
  final List<Map<String, dynamic>> _pending = [];
  final Map<String, DateTime> _recent = {};
  Future<void> _writes = Future.value();
  Future<void>? _sending;
  Timer? _retry;
  String? _lastError;
  DateTime? _lastErrorAt;
  String screen = 'room';
  bool _closed = false;

  ReportService(this.prefs, {http.Client? client, Uri? endpoint, this.context})
      : _client = client ?? http.Client(),
        endpoint = endpoint ?? Uri.parse('$hostedOrigin/v1/reports') {
    try {
      final saved = jsonDecode(prefs.getString('report_outbox') ?? '[]') as List;
      _pending.addAll(saved.whereType<Map>().take(60).map((v) => Map<String, dynamic>.from(v)));
    } catch (_) {/* A damaged outbox must not prevent startup. */}
  }

  String? get currentGame => _context()['game'];

  String? get draftGame => prefs.getString('feedback_draft_game');

  String get draft => prefs.getString('feedback_draft') ?? '';
  Future<void> saveDraft(String text, {String? game}) {
    final operation = _writes.catchError((Object _) {}).then((_) async {
      final targetSaved = game == null
          ? await prefs.remove('feedback_draft_game')
          : await prefs.setString('feedback_draft_game', game);
      if (!targetSaved || !await prefs.setString('feedback_draft', _limit(text, 6000))) {
        throw StateError('Could not save feedback on this phone.');
      }
    });
    _writes = operation;
    return operation;
  }

  void start() {
    _retry ??= Timer.periodic(const Duration(minutes: 1), (_) => unawaited(flush()));
    unawaited(flush());
  }

  Map<String, String> _context() {
    final extra = context?.call() ?? const <String, String>{};
    return {
      'app_version': '0.1.0+$appBuild',
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      'screen': _limit(screen, 80),
      if (extra['game'] case final String game)
        if (RegExp(r'^[a-z0-9-]{1,80}$').hasMatch(game)) 'game': game,
    };
  }

  static String _id() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static String _limit(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);

  /// Stack frames are useful; arbitrary exception messages may contain profile
  /// data or login links, so only the exception type is sent automatically.
  void captureError(Object error, StackTrace stack, {String source = 'unhandled'}) {
    captureFailure('$source: ${error.runtimeType}', stack: stack);
  }

  void captureFailure(String message, {StackTrace? stack}) {
    if (_closed) return;
    final safe = redact(message);
    final now = DateTime.now();
    _recent.removeWhere((_, at) => now.difference(at) > const Duration(minutes: 5));
    if (_recent.containsKey(safe) || _recent.length >= 20) return;
    _recent[safe] = now;
    final id = _id();
    _lastError = id;
    _lastErrorAt = now;
    // Automatic diagnostics are best effort. Never recurse through the global
    // error handler if local storage or the reporting service itself fails.
    unawaited(_enqueue({
      'id': id,
      'kind': 'error',
      'text': _limit(safe, 6000),
      if (stack != null) 'stack': _limit(redact(stack.toString()), 12000),
      'context': _context(),
    }).then((_) => flush()).catchError((Object _) {}));
  }

  static String redact(String value) => value
      .replaceAll(RegExp(r'https?://[^\s)]+', caseSensitive: false), '[url]')
      .replaceAll(RegExp(r'[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}'), '[email]')
      .replaceAll(RegExp(r'(?:Bearer\s+)[^\s]+', caseSensitive: false), '[credential]')
      .replaceAll(RegExp(r'\b[a-zA-Z0-9_-]{32,}\b'), '[token]')
      .replaceAll(RegExp(r'\b\d{6,8}\b'), '[code]')
      .replaceAll(RegExp(r'(?:[A-Za-z]:[\\/]|/home/|/Users/)[^\s)]+'), '[path]');

  Future<void> _enqueue(Map<String, dynamic> report) {
    final operation = _writes.catchError((Object _) {}).then((_) async {
      if (_pending.length >= 60) {
        final index = _pending.indexWhere((r) => r['kind'] == 'error');
        if (index < 0) {
          throw StateError('Feedback storage is full. Connect to the internet and try again.');
        }
        _pending.removeAt(index);
      }
      _pending.add(report);
      if (!await prefs.setString('report_outbox', jsonEncode(_pending))) {
        _pending.remove(report);
        throw StateError('Could not save this report.');
      }
    });
    _writes = operation;
    return operation;
  }

  /// False means safely saved for automatic retry, not discarded.
  Future<bool> submitFeedback(String text, {String? game}) async {
    if (game != null && !RegExp(r'^[a-z0-9-]{1,80}$').hasMatch(game)) {
      throw ArgumentError('Choose a valid game.');
    }
    text = text.trim();
    if (text.isEmpty || text.length > 6000) {
      throw ArgumentError('Write a little feedback first (up to 6000 characters).');
    }
    final id = _id();
    await _enqueue({
      'id': id,
      'kind': 'feedback',
      if (game != null) 'game': game,
      'text': text,
      'context': _context(),
      if (_lastErrorAt != null &&
          DateTime.now().difference(_lastErrorAt!) < const Duration(minutes: 15))
        'related_error': _lastError,
    });
    // It is durably queued now. Keep it exactly once even if sending times out.
    await saveDraft('');
    await flush();
    return !_pending.any((r) => r['id'] == id);
  }

  Future<void> flush() {
    if (_closed) return Future.value();
    return _sending ??= _flush().whenComplete(() => _sending = null);
  }

  Future<void> _flush() async {
    try {
      await _writes;
      for (final report in List<Map<String, dynamic>>.of(_pending)) {
        if (_closed) return;
        final result = await _client
            .post(endpoint, headers: {'Content-Type': 'application/json'}, body: jsonEncode(report))
            .timeout(const Duration(seconds: 12));
        if (result.statusCode < 200 || result.statusCode >= 300) return;
        final response = jsonDecode(result.body);
        if (response is! Map || response['id'] != report['id']) return;
        final operation = _writes.catchError((Object _) {}).then((_) async {
          final remaining = _pending.where((r) => r['id'] != report['id']).toList();
          if (await prefs.setString('report_outbox', jsonEncode(remaining))) {
            _pending.removeWhere((r) => r['id'] == report['id']);
          }
        });
        _writes = operation;
        await operation;
      }
    } catch (_) {/* Retain outbox. Idempotency makes retries safe. */}
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _client.close();
  }
}
