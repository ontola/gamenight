import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'account.dart';
import 'api.dart';

String assistantId() {
  final b = List.generate(16, (_) => Random.secure().nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String gameTitle(String id) => id
    .split(RegExp('[-_]'))
    .map((s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}')
    .join(' ');

/// Uses the existing authenticated room API. No provider keys or model
/// execution live in the app. A quote never sends a paid request by itself.
class Assistant extends ChangeNotifier {
  Assistant(this.cloud);
  final CloudApi cloud;
  Map<String, dynamic>? status;
  List<Map<String, dynamic>> presets = [];
  String draft = '', notice = '';
  String? error;
  bool busy = false, loading = false;
  int? quote;
  String? _id, pending;
  String? _context;
  bool _disposed = false;
  int _generation = 0;
  Map<String, dynamic>? get controls => status?['controls'] is Map
      ? Map<String, dynamic>.from(status!['controls'] as Map)
      : null;
  List<Map<String, dynamic>> get requests => [
        for (final r in status?['requests'] as List? ?? [])
          if (r is Map) Map<String, dynamic>.from(r)
      ];
  bool get waiting =>
      pending != null ||
      requests.any((r) => r['state'] == 'thinking' || r['state'] == 'queued');
  bool get local => status?['local_model'] == true;
  bool get owner => status?['can_fund'] == true;
  bool get available => status?['provider_configured'] == true;
  bool get canSend => available && !busy && !waiting && draft.trim().isNotEmpty;
  static const _errors = {
    400: 'This request could not be used. Check it and try again.',
    401:
        'Sign in to use the Assistant. Playing games does not require an account.',
    403:
        'Join a running room. Some changes are only available to its main player.',
    402: 'Set a session spending limit and check that you have enough credits.',
    409:
        'The game changed or another request is running. Refresh and try again.',
    412: 'The estimate changed. Edit or review your request again.',
    503:
        'The AI provider is not configured. You can still play and use game settings.',
  };
  Future<dynamic> _request(String method, String suffix, [Object? body]) =>
      cloud.request(method, '/v1/rooms/agent$suffix',
          body: body, errors: _errors);
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void setDraft(String value) {
    if (value == draft) return;
    draft = value;
    quote = null;
    _id = null;
    error = null;
    notice = '';
    _changed();
  }

  /// Never carry an estimate, request or history across account/room changes.
  void reset() {
    _generation++;
    status = null;
    presets = [];
    quote = null;
    _id = null;
    pending = null;
    _context = null;
    error = null;
    notice = '';
    busy = false;
    loading = false;
    draft = '';
    _changed();
  }

  Future<void> refresh() async {
    if (loading || _disposed) return;
    final generation = _generation;
    loading = true;
    try {
      final data = await _request('GET', '');
      if (_disposed || generation != _generation) return;
      status = Map<String, dynamic>.from(data as Map);
      final context = jsonEncode([
        controls?['game'],
        controls?['instance'],
        controls?['revision'],
        local
      ]);
      if (_context != null && context != _context) {
        quote = null;
        if (pending == null) _id = null;
      }
      _context = context;
      for (final r in requests) {
        if (r['id'] == pending &&
            !['thinking', 'queued'].contains(r['state'])) {
          notice = r['result'] as String? ??
              (r['state'] == 'complete'
                  ? 'Done.'
                  : 'The change was not completed.');
          pending = null;
        }
      }
      // A successful refresh clears connection errors, not action errors.
    } catch (e) {
      if (!_disposed && generation == _generation) {
        status = null;
        error = e is ApiError
            ? e.message
            : 'Could not connect to your room. Try again.';
      }
    } finally {
      if (generation == _generation) {
        loading = false;
        _changed();
      }
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (busy || _disposed) return;
    final generation = _generation;
    busy = true;
    error = null;
    notice = '';
    _changed();
    try {
      await operation();
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error = e is ApiError
            ? e.message
            : 'Could not reach the Assistant. Your request is still here.';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> send() async {
    if (!canSend) return;
    if (utf8.encode(draft.trim()).length > 2000) {
      error = 'Keep your request under 2,000 bytes. Shorten it and try again.';
      _changed();
      return;
    }
    final text = draft.trim(),
        id = _id ??= assistantId(),
        generation = _generation;
    await _run(() async {
      if (!local && quote == null) {
        final result =
            await _request('POST', '/quote', {'request_id': id, 'text': text});
        if (generation != _generation || _disposed) return;
        quote = (result['maximum_credits'] as num).toInt();
        return;
      }
      await _request('POST', '',
          {'request_id': id, 'text': text, 'max_credits': local ? 0 : quote});
      if (generation != _generation || _disposed) return;
      pending = id;
      draft = '';
      quote = null;
      _id = null;
      notice = 'Thinking…';
      await refresh();
    });
  }

  Future<void> fund(int cap) => _run(() async {
        await _request('POST', '/funding', {'cap': cap, 'party': false});
        await refresh();
      });
  Future<void> control(String action) async {
    final c = controls;
    if (c == null || !owner || waiting) return;
    final id = assistantId(), generation = _generation;
    await _run(() async {
      await _request('POST', '/control', {
        'request_id': id,
        'command': {
          'action': action,
          'instance': c['instance'],
          'expected_revision': c['revision'],
          'values': action == 'launch'
              ? {'players': c['launch_players']}
              : <String, Object>{}
        }
      });
      if (generation != _generation || _disposed) return;
      pending = id;
      notice = 'Waiting for the game…';
      await refresh();
    });
  }

  Future<void> loadPresets() async {
    final generation = _generation;
    try {
      final data = await _request('GET', '/presets');
      if (_disposed || generation != _generation) return;
      presets = [
        for (final p in data['presets'] as List)
          Map<String, dynamic>.from(p as Map)
      ];
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error =
            e is ApiError ? e.message : 'Could not load saved configurations.';
      }
    }
    _changed();
  }

  Future<void> savePreset(String name, {String? id}) async {
    final c = controls;
    if (c == null || waiting || name.trim().isEmpty) return;
    await _run(() async {
      await _request('POST', '/presets', {
        'action': 'save',
        'name': name.trim(),
        if (id != null) 'id': id,
        'game': c['game'],
        'instance': c['instance'],
        'expected_revision': c['revision']
      });
      notice = 'Configuration saved.';
      await loadPresets();
    });
  }

  Future<void> deletePreset(String id) => _run(() async {
        await _request('POST', '/presets', {'action': 'delete', 'id': id});
        notice = 'Configuration deleted.';
        await loadPresets();
      });
  Future<void> applyPreset(Map<String, dynamic> preset) async {
    final c = controls;
    if (c == null || !owner || waiting || c['game'] != preset['game']) return;
    final id = assistantId(), generation = _generation;
    await _run(() async {
      await _request('POST', '/presets/apply', {
        'id': preset['id'],
        'request_id': id,
        'instance': c['instance'],
        'expected_revision': c['revision']
      });
      if (generation != _generation || _disposed) return;
      pending = id;
      notice = 'Waiting for the game…';
      await refresh();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
