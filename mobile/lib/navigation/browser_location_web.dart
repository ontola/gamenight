import 'package:web/web.dart' as web;

void back() => web.window.history.back();
void cleanLaunchUrl() {
  // main() already captured the launch invitation. Later history entries must
  // not replay or retain its room/pair/email parameters.
  web.window.history
      .replaceState(web.window.history.state, '', web.window.location.pathname);
}
