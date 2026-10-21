import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'account.dart';

/// Kept injectable so account lifecycle tests need no native Firebase runtime.
abstract class PushDevice {
  String get platform;
  Stream<String> get tokens;
  Stream<String> get opened;
  Stream<String> get foreground;
  Future<String?> initialRoom();
  Future<String?> requestToken();
  Future<void> deleteToken();
}

class FirebasePushDevice implements PushDevice {
  static Future<PushDevice?> create() async {
    if (!const bool.fromEnvironment('GAMENIGHT_PUSH') ||
        kIsWeb ||
        ![TargetPlatform.android, TargetPlatform.iOS]
            .contains(defaultTargetPlatform)) {
      return null;
    }
    try {
      await Firebase.initializeApp();
      return FirebasePushDevice();
    } catch (_) {
      // Local builds without provider configuration still work normally.
      debugPrint('Push notifications are unavailable.');
      return null;
    }
  }

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;
  @override
  String get platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
  @override
  // The cloud uses HTTP v1 registration tokens; FID migration is separate.
  // ignore: deprecated_member_use
  Stream<String> get tokens => _messaging.onTokenRefresh;
  static String? _room(RemoteMessage message) {
    final room = message.data['room_code'];
    return room is String && RegExp(r'^[A-Z0-9]{6}$').hasMatch(room)
        ? room
        : null;
  }

  @override
  Stream<String> get opened => FirebaseMessaging.onMessageOpenedApp
      .map(_room)
      .where((room) => room != null)
      .cast<String>();
  @override
  Stream<String> get foreground => FirebaseMessaging.onMessage
      .map(_room)
      .where((room) => room != null)
      .cast<String>();
  @override
  Future<String?> initialRoom() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _room(message);
  }

  @override
  Future<String?> requestToken() async {
    final permission = await _messaging.requestPermission();
    if (permission.authorizationStatus != AuthorizationStatus.authorized &&
        permission.authorizationStatus != AuthorizationStatus.provisional) {
      return null;
    }
    await _messaging.setAutoInitEnabled(true);
    // APNs registration is asynchronous. A later foreground resume retries if
    // iOS has not supplied its token within this bounded window.
    if (platform == 'ios') {
      for (var attempt = 0;
          await _messaging.getAPNSToken() == null;
          attempt++) {
        if (attempt == 9) return null;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    // ignore: deprecated_member_use
    return _messaging.getToken();
  }

  @override
  Future<void> deleteToken() async {
    await _messaging.setAutoInitEnabled(false);
    // ignore: deprecated_member_use
    await _messaging.deleteToken();
  }
}

/// Serializes registrations and logout. Permission/token retrieval never holds
/// up signing in, and a result arriving after logout cannot re-register a phone.
class AccountPush {
  final CloudApi cloud;
  final PushDevice? device;
  StreamSubscription<String>? _refresh;
  Future<void> _queue = Future.value();
  int _generation = 0;
  bool _active = false;
  bool _disposed = false;
  String? _registered;
  String? _identity;

  AccountPush(this.cloud, this.device);

  Future<void> _serialize(Future<void> Function() action) {
    return _queue = _queue.then((_) => action()).catchError((Object _) {
      // Notification failures never break account or room operations.
      debugPrint('Could not update push registration.');
    });
  }

  Future<void> sync() async {
    if (device == null || !cloud.signedIn || _disposed) return;
    if (_identity != cloud.token) {
      _identity = cloud.token;
      _registered = null;
      _generation++;
    }
    _active = true;
    _refresh ??= device!.tokens.listen((token) {
      if (_active) unawaited(_register(token, _generation));
    }, onError: (Object _) {});
    final generation = _generation;
    try {
      final token = await device!.requestToken();
      if (token != null) await _register(token, generation);
    } catch (_) {
      debugPrint('Could not obtain a push token.');
    }
  }

  Future<void> _register(String token, int generation) => _serialize(() async {
        if (!_active ||
            _disposed ||
            generation != _generation ||
            _identity != cloud.token ||
            !cloud.signedIn ||
            token == _registered) {
          return;
        }
        await cloud.request('POST', '/v1/me/push-token', body: {
          'token': token,
          'platform': device!.platform,
        });
        final previous = _registered;
        _registered = token;
        if (previous != null && previous != token) {
          await cloud.request('DELETE', '/v1/me/push-token',
              body: {'token': previous});
        }
      });

  Future<void> signOut() {
    _active = false;
    _generation++;
    return _serialize(() async {
      final token = _registered;
      _registered = null;
      try {
        if (token != null && cloud.signedIn) {
          await cloud
              .request('DELETE', '/v1/me/push-token', body: {'token': token});
        }
      } finally {
        // Also invalidate at FCM, including when the cloud is unreachable.
        await device?.deleteToken().timeout(const Duration(seconds: 5));
      }
    });
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _refresh?.cancel();
  }
}
