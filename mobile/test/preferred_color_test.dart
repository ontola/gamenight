import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/faces.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final guest in [false, true]) {
    test(
        'preferred colour saves for ${guest ? "guest" : "account"} without rejoining',
        () async {
      SharedPreferences.setMockInitialValues({
        guest ? 'guest_room_token' : 'cloud_token': 'test-only',
        if (guest) 'hosted_room': true,
      });
      final saved = Completer<Map<String, dynamic>>();
      final cloud = CloudApi(client: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path,
            guest ? '/v1/rooms/guest/profile' : '/v1/me/studio');
        if (guest) {
          expect(request.headers['X-GameNight-Room-Token'], 'test-only');
          expect(request.headers['Authorization'], isNull);
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (!saved.isCompleted) saved.complete(body);
        return guest
            ? http.Response('', 204)
            : http.Response(jsonEncode({...body, 'revision': 1}), 200);
      }));
      final prefs = await SharedPreferences.getInstance();
      final state = AppState(prefs, cloud: cloud);
      addTearDown(state.dispose);
      state.setClothing('#ff5555');
      final body = await saved.future.timeout(const Duration(seconds: 3));
      expect((guest ? body : body['profile'])['preferred_color'], '#ff5555');
      expect(prefs.getString('clothing_color'), '#ff5555');
      expect(decodeBackup(state.exportBackup()).preferredColor, '#ff5555');
    });
  }
}
