// A GameNight account on gamenight.ontola.io: email sign-in, the saved
// player (name, skin, faces) and hosted rooms joined by room code.
//
// The website signs in with cookies; the app does the same exchange by hand
// and then uses the session as a bearer token, which the server accepts
// without the browser's CSRF header.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'api.dart' show ApiError;
import 'link.dart';
import 'diagnostics.dart';

class Account {
  final String id;
  final String? displayName;
  const Account({required this.id, this.displayName});

  static Account fromJson(Map<String, dynamic> j) => Account(
      id: j['id'] as String,
      displayName: (j['profile'] as Map?)?['display_name'] as String?);
}

/// `GET /v1/me/studio`: the saved player and every face, in the studio's
/// backup format (the same one the app exports).
class StudioDocument {
  final int revision;
  final String? displayName;
  final String? skinColor;
  final String? preferredColor;
  final Map<String, dynamic>? workspace;
  const StudioDocument(
      {required this.revision,
      this.displayName,
      this.skinColor,
      this.preferredColor,
      this.workspace});

  static StudioDocument fromJson(Map<String, dynamic> j) {
    final profile = j['profile'] as Map?;
    return StudioDocument(
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        displayName: profile?['display_name'] as String?,
        skinColor: profile?['skin_color'] as String?,
        preferredColor: profile?['preferred_color'] as String?,
        workspace: j['workspace'] as Map<String, dynamic>?);
  }
}

/// `GET /v1/rooms/status` for a hosted room.
class HostedRoom {
  /// `none`, `waiting` (walk to your door in the lobby) or `connected`.
  final String status;
  final String? code;
  final int players;
  final bool remembered;
  final bool mainPlayer;
  final bool fresh;
  final String? current;
  final String? next;
  final int? expires;
  final Map<String, dynamic> raw;

  HostedRoom(this.raw)
      : status = raw['status'] as String? ?? 'none',
        code = raw['room_code'] as String?,
        players = (raw['players'] as num?)?.toInt() ?? 0,
        remembered = raw['remembered'] == true,
        mainPlayer = raw['main_player'] == true,
        fresh = raw['fresh'] == true,
        current = (raw['discovery'] as Map?)?['current'] as String?,
        next = (raw['discovery'] as Map?)?['next'] as String?,
        expires = (raw['expires'] as num?)?.toInt();

  String? get currentTitle {
    if (current == null) return null;
    final discovery = raw['discovery'];
    if (discovery is Map) {
      final entries = (discovery['playlist'] as Map?)?['entries'];
      if (entries is List) {
        for (final entry in entries) {
          if (entry is Map &&
              entry['game'] == current &&
              entry['title'] is String) {
            return entry['title'] as String;
          }
        }
      }
    }
    return current;
  }

  bool get connected => status == 'connected';
  bool get waiting => status == 'waiting';
  bool get choosingPlayer => status == 'choose_player';
  bool get guest => raw['guest'] == true;
  List<Map<String, dynamic>> get seats => (raw['seats'] as List? ?? [])
      .whereType<Map>()
      .map((v) => Map<String, dynamic>.from(v))
      .toList();
  bool get none => !connected && !waiting && !choosingPlayer;
}

/// `GET /v1/pairing/<ticket>`: what a hosted lobby QR would connect.
class PairingPreview {
  final int seat;
  final bool remembered;
  final bool mainAvailable;
  PairingPreview(Map<String, dynamic> j)
      : seat = (j['seat'] as num?)?.toInt() ?? 0,
        remembered = j['remembered'] == true,
        mainAvailable = j['main_available'] == true;
}

class SignedOut extends ApiError {
  const SignedOut() : super('Your sign-in expired. Sign in again.');
}

class GuestRoomExpired extends ApiError {
  const GuestRoomExpired()
      : super('Your room connection expired. Scan the QR on the TV again.');
}

class CloudApi {
  final Uri base;
  final http.Client _client;
  String? token;
  String? guestToken;
  bool get hasRoomSession => token != null || guestToken != null;
  Object get roomIdentity => (token, guestToken);
  final bool browserCookies;
  String? _browserCsrf;
  // Local state only. HttpOnly cookies, never these markers, authenticate web.
  static const _browserSession = 'browser-cookie-session';
  static const _browserBinding = 'browser-cookie-binding';

  /// Ties an emailed code to this phone, like the website's browser cookie.
  String? emailBinding;

  /// The site sign-in requests must come from; only differs in tests.
  final String origin;

  CloudApi(
      {Uri? base,
      http.Client? client,
      this.token,
      String? origin,
      this.browserCookies = kIsWeb})
      : base = base ?? Uri.parse(hostedOrigin),
        origin = origin ?? (base ?? Uri.parse(hostedOrigin)).origin,
        _client = client ?? http.Client();

  static const _timeout = Duration(seconds: 15);

  bool get signedIn => token != null;

  void close() => _client.close();

  Future<http.Response> _raw(String method, String path,
      {Object? body, Map<String, String> headers = const {}}) async {
    final guestPath = path == '/v1/rooms/guest' ||
        path == '/v1/rooms/status' ||
        path == '/v1/rooms/companion' ||
        path == '/v1/rooms/next' ||
        path.startsWith('/v1/rooms/guest/');
    final usesGuest = guestToken != null && guestPath;
    final cookieMutation = browserCookies &&
        !(usesGuest && path != '/v1/rooms/guest/upgrade') &&
        path != '/v1/rooms/guest' &&
        !path.startsWith('/auth/email/') &&
        !const ['GET', 'HEAD', 'OPTIONS'].contains(method);
    if (cookieMutation && _browserCsrf == null) {
      final session = await _raw('GET', '/auth/session');
      if (session.statusCode == 401) {
        token = null;
        throw const SignedOut();
      }
      final data = session.statusCode == 200 ? jsonDecode(session.body) : null;
      if (data is! Map ||
          data['csrf'] is! String ||
          (data['csrf'] as String).isEmpty) {
        throw const ApiError('Could not confirm your sign-in. Try again.');
      }
      _browserCsrf = data['csrf'] as String;
    }
    final request = http.Request(method, base.replace(path: path));
    request.headers.addAll({
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      // Sign-in only answers requests from its own site.
      if (!browserCookies) 'Origin': origin,
      if (!browserCookies &&
          token != null &&
          (!usesGuest || path == '/v1/rooms/guest/upgrade'))
        'Authorization': 'Bearer $token',
      if (usesGuest) 'X-GameNight-Room-Token': guestToken!,
      if (cookieMutation) 'X-GameNight-CSRF': _browserCsrf!,
      ...headers,
    });
    if (body != null) request.body = jsonEncode(body);
    try {
      final response = await http.Response.fromStream(
          await _client.send(request).timeout(_timeout));
      if (browserCookies &&
          (response.statusCode == 401 || response.statusCode == 403)) {
        _browserCsrf = null;
      }
      if (response.statusCode >= 500) {
        Diagnostics.failure(
            'Cloud $method failed (HTTP ${response.statusCode})');
      }
      return response;
    } on TimeoutException {
      Diagnostics.failure('Cloud $method timed out');
      throw const ApiError(
          'GameNight online did not answer. Check your internet.');
    } catch (_) {
      Diagnostics.failure('Cloud $method connection failed');
      throw const ApiError(
          'Could not reach GameNight online. Check your internet.');
    }
  }

  Future<dynamic> _send(String method, String path,
      {Object? body, Map<int, String> errors = const {}}) async {
    final response = await _raw(method, path, body: body);
    final status = response.statusCode;
    if (status == 401 &&
        guestToken != null &&
        (path == '/v1/rooms/status' ||
            path == '/v1/rooms/companion' ||
            path == '/v1/rooms/next' ||
            path.startsWith('/v1/rooms/guest/')) &&
        path != '/v1/rooms/guest/upgrade') {
      guestToken = null;
      throw const GuestRoomExpired();
    }
    if (status == 401 && token != null) {
      token = null;
      throw const SignedOut();
    }
    if (status >= 200 && status < 300) {
      return status == 204 || response.body.isEmpty
          ? null
          : jsonDecode(response.body);
    }
    if (errors.containsKey(status)) throw ApiError(errors[status]!);
    if (status == 429) {
      throw const ApiError('Too many attempts. Wait a minute and try again.');
    }
    throw ApiError('GameNight online answered $status. Try again.');
  }

  static String? cookie(http.Response response, String name) {
    final header = response.headers['set-cookie'];
    if (header == null) return null;
    final match = RegExp('(?:^|[,;]\\s*)$name=([^;,]*)').firstMatch(header);
    final value = match?.group(1);
    return value == null || value.isEmpty ? null : value;
  }

  // ---- Sign-in ---------------------------------------------------------

  /// Cookie-authenticated requests made outside CloudApi (such as feedback).
  /// Refresh on every call so another tab's sign-in cannot leave a stale CSRF.
  Future<Map<String, String>> browserMutationHeaders() async {
    if (!browserCookies) return {};
    final response = await _raw('GET', '/auth/session');
    if (response.statusCode == 401) return {};
    final data = response.statusCode == 200 ? jsonDecode(response.body) : null;
    if (data is! Map ||
        data['csrf'] is! String ||
        (data['csrf'] as String).isEmpty) {
      throw const ApiError('Could not confirm your sign-in. Try again.');
    }
    _browserCsrf = data['csrf'] as String;
    return {'X-GameNight-CSRF': _browserCsrf!};
  }

  /// Recognize email-link sign-in and existing sessions in this browser.
  /// A local marker is never proof of a session; the server checks its cookie.
  Future<bool> restoreBrowserSession() async {
    if (!browserCookies) return signedIn;
    final response = await _raw('GET', '/auth/session');
    if (response.statusCode == 401) {
      token = null;
      _browserCsrf = null;
      return false;
    }
    final data = response.statusCode == 200 ? jsonDecode(response.body) : null;
    if (data is! Map ||
        data['csrf'] is! String ||
        (data['csrf'] as String).isEmpty) {
      throw const ApiError('Could not confirm your sign-in. Try again.');
    }
    token = _browserSession;
    _browserCsrf = data['csrf'] as String;
    emailBinding = null;
    return true;
  }

  /// Emails an 8-digit code (and a link) to [email].
  Future<void> requestCode(String email, {String? returnTo}) async {
    final response = await _raw('POST', '/auth/email/request', body: {
      'email': email.trim(),
      'client': browserCookies ? 'browser' : 'app',
      if (browserCookies) 'return_to': returnTo ?? '/app/'
    });
    switch (response.statusCode) {
      case 204:
        emailBinding =
            browserCookies ? _browserBinding : cookie(response, 'gn_email');
        if (emailBinding == null) {
          throw const ApiError('Sign-in is not available right now.');
        }
        return;
      case 400:
        throw const ApiError('That does not look like an email address.');
      case 429:
        throw const ApiError(
            'Too many codes asked for. Wait a minute and try again.');
      case 404:
      case 405:
        throw const ApiError('Email sign-in is not available right now.');
      default:
        throw const ApiError('Could not send the email. Try again.');
    }
  }

  /// Trades the emailed code for a session.
  Future<void> verifyCode(String code) async {
    final binding = emailBinding;
    if (binding == null) throw const ApiError('Ask for a new code first.');
    final response = await _raw('POST', '/auth/email/verify',
        body: {'code': code.trim()},
        headers: {if (!browserCookies) 'Cookie': 'gn_email=$binding'});
    switch (response.statusCode) {
      case 204:
        final session =
            browserCookies ? _browserSession : cookie(response, 'gn_session');
        if (session == null) throw const ApiError('Sign-in failed. Try again.');
        token = session;
        _browserCsrf = null;
        emailBinding = null;
        return;
      case 400:
        throw const ApiError('The code has 8 digits.');
      case 401:
        throw const ApiError(
            'That code is wrong or expired. Check it, or ask for a new one.');
      default:
        throw const ApiError('Sign-in failed. Try again.');
    }
  }

  Future<void> signOut() async {
    try {
      if (token != null) await _send('DELETE', '/v1/session');
    } on ApiError {
      // Forgetting the token signs this phone out either way.
    }
    token = null;
    _browserCsrf = null;
  }

  // ---- Saved player ----------------------------------------------------

  Future<Account> me() async => Account.fromJson(await _send('GET', '/v1/me'));

  Future<StudioDocument> studio() async =>
      StudioDocument.fromJson(await _send('GET', '/v1/me/studio'));

  /// Saves the player and all faces. Answers the new revision; null when
  /// another device saved first.
  Future<StudioDocument?> saveStudio(
      {required int revision,
      required String displayName,
      required String skinColor,
      String? preferredColor,
      required String avatar,
      required Map<String, dynamic> workspace}) async {
    final response = await _raw('PUT', '/v1/me/studio', body: {
      'revision': revision,
      'profile': {
        'display_name': displayName,
        'skin_color': skinColor,
        if (preferredColor != null) 'preferred_color': preferredColor,
        'avatar': avatar
      },
      'workspace': workspace,
    });
    switch (response.statusCode) {
      case 200:
        return StudioDocument.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>);
      case 409:
        return null;
      case 401:
        token = null;
        throw const SignedOut();
      case 422:
      case 400:
        throw const ApiError(
            'GameNight online did not accept this player. Check the name.');
      default:
        throw const ApiError(
            'Not synced to your account. Your player is kept on this phone.');
    }
  }

  // ---- Hosted rooms ----------------------------------------------------

  Future<HostedRoom> joinGuest(
      {String? code,
      String? ticket,
      required Map<String, dynamic> profile}) async {
    final response = await _send('POST', '/v1/rooms/guest', body: {
      if (code != null) 'code': code,
      if (ticket != null) 'ticket': ticket,
      'profile': profile,
    }, errors: {
      404: 'No room with that code. Check the code on the TV.',
      410: 'This QR expired. Scan the QR on the TV again.',
      409: 'That player is already connected. Scan another player’s QR.',
    });
    if (response is! Map ||
        response['token'] is! String ||
        (response['token'] as String).isEmpty ||
        response['status'] is! Map) {
      throw const ApiError('Could not join the room. Try scanning again.');
    }
    guestToken = response['token'] as String;
    return HostedRoom(Map<String, dynamic>.from(response['status'] as Map));
  }

  Future<void> updateGuestProfile(Map<String, dynamic> profile) async {
    await _send('PUT', '/v1/rooms/guest/profile', body: profile);
  }

  Future<void> chooseGuestSeat(Map<String, dynamic> seat) async {
    await _send('POST', '/v1/rooms/guest/seat', body: {
      'index': seat['index'],
      'player': seat['player'],
      'revision': seat['revision'],
    }, errors: {
      409: 'That player was just taken. Choose another player.',
      410: 'The players have changed. Choose your player again.'
    });
  }

  Future<void> upgradeGuest() async {
    if (guestToken == null) return;
    await _send('POST', '/v1/rooms/guest/upgrade', body: {}, errors: {
      409:
          'Your account already has a player in this room. Your guest game is still connected.',
      410: 'Your guest connection expired. Scan the QR on the TV again.',
    });
    guestToken = null;
  }

  Future<void> leaveGuest() async {
    if (guestToken == null) return;
    await _send('POST', '/v1/rooms/guest/leave', body: {});
    guestToken = null;
  }

  Future<void> joinRoom(String code, {bool remember = false}) =>
      _send('POST', '/v1/rooms/join', body: {
        'code': code,
        if (remember) 'remember': true
      }, errors: {
        404: 'No room with that code. Check the code on the TV.',
        409: 'You are already in this room.',
      });

  Future<HostedRoom> roomStatus() async => HostedRoom(
      await _send('GET', '/v1/rooms/status') as Map<String, dynamic>);

  Future<void> cancelPickup() => _send('POST', '/v1/rooms/cancel', body: {});

  Future<void> leaveRoom() => _send('POST', '/v1/pairing/unlink', body: {});

  Future<void> remember(String code, bool remember) =>
      _send('POST', '/v1/rooms/remember',
          body: {'code': code, 'remember': remember});

  Future<void> mainPlayer(String code, bool enabled) =>
      _send('POST', '/v1/rooms/main-player',
          body: {'code': code, 'enabled': enabled});

  /// Other room calls, for the Game tab's controls.
  Future<dynamic> request(String method, String path,
          {Object? body, Map<int, String> errors = const {}}) =>
      _send(method, path, body: body, errors: errors);

  Future<PairingPreview> pairing(String ticket) async => PairingPreview(
      await _send('GET', '/v1/pairing/${Uri.encodeComponent(ticket)}',
          errors: {404: 'This QR expired. Scan the lobby QR again.'}));

  Future<void> claim(String ticket, {bool remember = false}) =>
      _send('POST', '/v1/pairing/claim', body: {
        'ticket': ticket,
        'remember': remember
      }, errors: {
        410: 'This QR expired. Scan the lobby QR again.',
        404: 'This QR expired. Scan the lobby QR again.',
      });
}
