import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../link.dart';
import 'website_session_stub.dart'
    if (dart.library.js_interop) 'website_session_web.dart' as browser;

/// Move an existing same-origin website room into the app without a fresh pickup.
/// Capabilities stay in browser storage, never in redirects or history.
Future<void> migrateWebsiteRoom(SharedPreferences prefs,
    {String? guest, String? saved}) async {
  guest ??= browser.readGuest();
  saved ??= browser.readSavedRoom();
  if (prefs.getString('guest_room_token') != null) {
    browser.clearLegacyRoom();
    return;
  }
  try {
    final data = jsonDecode(guest ?? saved ?? 'null');
    if (data is! Map) return;
    final token = data['token'];
    final room = data['room'];
    if (token is String && token.isNotEmpty && token.length <= 512) {
      await prefs.setString('guest_room_token', token);
      if (room is String && isRoomCode(room)) {
        await prefs.setString('guest_room_invitation', '/app/?room=$room');
      }
      final profile = data['profile'];
      if (profile is Map) {
        if (profile['display_name'] is String) {
          await prefs.setString('player_name', profile['display_name']);
        }
        if (profile['skin_color'] is String &&
            RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(profile['skin_color'])) {
          await prefs.setString('skin_color', profile['skin_color']);
        }
        if (profile['avatar'] is String) {
          await prefs.setString('face', profile['avatar']);
        }
      }
    } else if (saved == null) {
      return;
    }
    await prefs.setBool('hosted_room', true);
    browser.clearLegacyRoom();
  } catch (_) {/* Invalid old storage must not prevent launching the app. */}
}
