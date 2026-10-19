import 'package:url_launcher/url_launcher.dart';
import '../app_state.dart';
import '../link.dart';

/// Opens a website page in the browser, signed in like the app when it is.
Future<void> openWebsite(AppState state, String path) async {
  Uri? url;
  try {
    url = await state.cloud.webHandoff(path);
  } catch (_) {
    // Fall back to the plain page; it offers its own sign-in.
  }
  await launchUrl(url ?? Uri.parse('$hostedOrigin$path'));
}
