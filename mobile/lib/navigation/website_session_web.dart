import 'package:web/web.dart' as web;

String? readGuest() {
  try {
    return web.window.sessionStorage.getItem('gamenight_guest_v1');
  } catch (_) {
    return null;
  }
}

String? readSavedRoom() {
  try {
    return web.window.sessionStorage.getItem('gamenight_saved_room');
  } catch (_) {
    return null;
  }
}

void clearLegacyRoom() {
  try {
    for (final key in [
      'gamenight_guest_v1',
      'gamenight_saved_room',
      'gamenight_guest_save',
      'gamenight_room_code',
      'gamenight_pair'
    ]) {
      web.window.sessionStorage.removeItem(key);
    }
  } catch (_) {}
}
