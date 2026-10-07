// A GameNight account on gamenight.ontola.io: email sign-in, the saved
// player (name, skin, faces) and hosted rooms joined by room code.
//
// The website signs in with cookies; the app does the same exchange by hand
// and then uses the session as a bearer token, which the server accepts
// without the browser's CSRF header.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart' show ApiError;
import 'link.dart';

class Account {
  final String id;
  final String? displayName;
  const Account({required this.id, this.displayName});

  static Account fromJson(Map<String, dynamic> j) => Account(
      id: j['id'] as String, displayName: (j['profile'] as Map?)?['display_name'] as String?);
}

/// `GET /v1/me/studio`: the saved player and every face, in the studio's
/// backup format (the same one the app exports).
class StudioDocument {
  final int revision;
  final String? displayName;
  final String? skinColor;
  final Map<String, dynamic>? workspace;
  const StudioDocument({required this.revision, this.displayName, this.skinColor, this.workspace});

  static StudioDocument fromJson(Map<String, dynamic> j) {
    final profile = j['profile'] as Map?;
    return StudioDocument(
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        displayName: profile?['display_name'] as String?,
        skinColor: profile?['skin_color'] as String?,
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

  bool get connected => status == 'connected';
  bool get waiting => status == 'waiting';
  bool get none => !connected && !waiting;
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

class CloudApi {
  final Uri base;
  final http.Client _client;
  String? token;

  /// Ties an emailed code to this phone, like the website's browser cookie.
  String? emailBinding;

  /// The site sign-in requests must come from; only differs in tests.
  final String origin;

  CloudApi({Uri? base, http.Client? client, this.token, String? origin})
      : base = base ?? Uri.parse(hostedOrigin),
        origin = origin ?? (base ?? Uri.parse(hostedOrigin)).origin,
        _client = client ?? http.Client();

  static const _timeout = Duration(seconds: 15);

  bool get signedIn => token != null;

  void close() => _client.close();

  Future<http.Response> _raw(String method, String path,
      {Object? body, Map<String, String> headers = const {}}) async {
    final request = http.Request(method, base.replace(path: path));
    request.headers.addAll({
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      // Sign-in only answers requests from its own site.
      'Origin': origin,
      if (token != null) 'Authorization': 'Bearer $token',
      ...headers,
    });
    if (body != null) request.body = jsonEncode(body);
    try {
      return await http.Response.fromStream(await _client.send(request).timeout(_timeout));
    } on TimeoutException {
      throw const ApiError('GameNight online did not answer. Check your internet.');
    } catch (_) {
      throw const ApiError('Could not reach GameNight online. Check your internet.');
    }
  }

  Future<dynamic> _send(String method, String path,
      {Object? body, Map<int, String> errors = const {}}) async {
    final response = await _raw(method, path, body: body);
    final status = response.statusCode;
    if (status == 401 && token != null) {
      token = null;
      throw const SignedOut();
    }
    if (status >= 200 && status < 300) {
      return status == 204 || response.body.isEmpty ? null : jsonDecode(response.body);
    }
    if (errors.containsKey(status)) throw ApiError(errors[status]!);
    if (status == 429) throw const ApiError('Too many attempts. Wait a minute and try again.');
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

  /// Emails an 8-digit code (and a link) to [email].
  Future<void> requestCode(String email) async {
    final response = await _raw('POST', '/auth/email/request', body: {'email': email.trim()});
    switch (response.statusCode) {
      case 204:
        emailBinding = cookie(response, 'gn_email');
        if (emailBinding == null) throw const ApiError('Sign-in is not available right now.');
        return;
      case 400:
        throw const ApiError('That does not look like an email address.');
      case 429:
        throw const ApiError('Too many codes asked for. Wait a minute and try again.');
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
        body: {'code': code.trim()}, headers: {'Cookie': 'gn_email=$binding'});
    switch (response.statusCode) {
      case 204:
        final session = cookie(response, 'gn_session');
        if (session == null) throw const ApiError('Sign-in failed. Try again.');
        token = session;
        emailBinding = null;
        return;
      case 400:
        throw const ApiError('The code has 8 digits.');
      case 401:
        throw const ApiError('That code is wrong or expired. Check it, or ask for a new one.');
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
      required String avatar,
      required Map<String, dynamic> workspace}) async {
    final response = await _raw('PUT', '/v1/me/studio', body: {
      'revision': revision,
      'profile': {'display_name': displayName, 'skin_color': skinColor, 'avatar': avatar},
      'workspace': workspace,
    });
    switch (response.statusCode) {
      case 200:
        return StudioDocument.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
      case 409:
        return null;
      case 401:
        token = null;
        throw const SignedOut();
      case 422:
      case 400:
        throw const ApiError('GameNight online did not accept this player. Check the name.');
      default:
        throw const ApiError('Not synced to your account. Your player is kept on this phone.');
    }
  }

  // ---- Hosted rooms ----------------------------------------------------

  Future<void> joinRoom(String code, {bool remember = false}) =>
      _send('POST', '/v1/rooms/join', body: {
        'code': code,
        if (remember) 'remember': true
      }, errors: {
        404: 'No room with that code. Check the code on the TV.',
        409: 'You are already in this room.',
      });

  Future<HostedRoom> roomStatus() async =>
      HostedRoom(await _send('GET', '/v1/rooms/status') as Map<String, dynamic>);

  Future<void> cancelPickup() => _send('POST', '/v1/rooms/cancel', body: {});

  Future<void> leaveRoom() => _send('POST', '/v1/pairing/unlink', body: {});

  Future<void> remember(String code, bool remember) =>
      _send('POST', '/v1/rooms/remember', body: {'code': code, 'remember': remember});

  Future<void> mainPlayer(String code, bool enabled) =>
      _send('POST', '/v1/rooms/main-player', body: {'code': code, 'enabled': enabled});

  /// Other room calls, for the Game tab's controls.
  Future<dynamic> request(String method, String path,
          {Object? body, Map<int, String> errors = const {}}) =>
      _send(method, path, body: body, errors: errors);

  Future<PairingPreview> pairing(String ticket) async =>
      PairingPreview(await _send('GET', '/v1/pairing/${Uri.encodeComponent(ticket)}',
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
