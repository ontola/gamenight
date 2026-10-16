import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gamenight/navigation/website_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('moves the existing guest capability and profile without joining again',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await migrateWebsiteRoom(prefs,
        guest: jsonEncode({
          'token': 'old-guest',
          'room': 'ABC234',
          'profile': {'display_name': 'Sunny Otter', 'skin_color': '#e5b28d'}
        }));
    expect(prefs.getString('guest_room_token'), 'old-guest');
    expect(prefs.getBool('hosted_room'), true);
    expect(prefs.getString('guest_room_invitation'), '/app/?room=ABC234');
    expect(prefs.getString('player_name'), 'Sunny Otter');
  });
  test('never replaces an existing app connection with stale website state',
      () async {
    SharedPreferences.setMockInitialValues({'guest_room_token': 'current'});
    final prefs = await SharedPreferences.getInstance();
    await migrateWebsiteRoom(prefs, guest: '{"token":"older"}');
    expect(prefs.getString('guest_room_token'), 'current');
  });
  test('invalid website storage cannot stop startup or invent a connection',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await migrateWebsiteRoom(prefs, guest: 'broken');
    expect(prefs.getBool('hosted_room'), null);
  });
}
