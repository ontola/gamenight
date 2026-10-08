// What a scanned lobby QR (or a typed address) points at.
//
// The lobby prints three kinds of local links, all served by the opt-in web
// server on the GameNight PC (port 7913 by default):
//   http://192.168.1.20:7913/?r=ABC234                     room code
//   http://192.168.1.20:7913/studio?claim=<id>&link_revision=2   a character
//   http://192.168.1.20:7913/mobile                         just the host
// When the lobby is online, its QR points at the website instead:
//   https://gamenight.ontola.io/studio#pair=<ticket>        a seat, needs sign-in
//   https://gamenight.ontola.io/studio#room=ABC234          a hosted room code
const int defaultWebPort = 7913;
const String hostedOrigin = 'https://gamenight.ontola.io';

final RegExp _roomCode = RegExp(r'^[A-HJ-NP-Z2-9]{6}$');

bool isRoomCode(String code) => _roomCode.hasMatch(code);

class HostLink {
  /// Origin of the local GameNight web server, e.g. `http://192.168.1.20:7913`.
  final Uri base;
  final String? roomCode;
  final String? claim;
  final int? seat;
  final int linkRevision;

  /// A hosted lobby's one-time seat ticket.
  final String? pair;

  const HostLink(this.base,
      {this.roomCode, this.claim, this.seat, this.linkRevision = 0, this.pair});

  bool get hosted => base.origin == hostedOrigin;
}

class LinkError implements Exception {
  final String message;
  const LinkError(this.message);
  @override
  String toString() => message;
}

/// Accepts a full lobby link, `host:port`, or a bare IP address.
HostLink parseHostLink(String input) {
  var text = input.trim();
  if (text.isEmpty) throw const LinkError('Enter the address shown in the lobby.');
  if (!text.contains('://')) text = 'http://$text';
  final Uri url;
  try {
    url = Uri.parse(text);
  } on FormatException {
    throw const LinkError('That is not a GameNight address.');
  }
  if (!['http', 'https'].contains(url.scheme) || url.host.isEmpty || url.userInfo.isNotEmpty) {
    throw const LinkError('That is not a GameNight address.');
  }
  final port = url.hasPort
      ? url.port
      : url.scheme == 'https'
          ? 443
          : (input.contains('://') ? 80 : defaultWebPort);
  final base = Uri(scheme: url.scheme, host: url.host, port: port);
  final path = url.path.isEmpty ? '/' : url.path;
  final known = path == '/' || RegExp(r'^/(session(/[^/]+)?|studio|mobile|join)/?$').hasMatch(path);
  if (!known) {
    throw const LinkError('This is not a GameNight sign-in QR. Try the code in the lobby.');
  }
  final q = url.queryParameters;
  final Map<String, String> fragment;
  try {
    fragment = Uri.splitQueryString(url.fragment);
  } on FormatException {
    throw const LinkError('That is not a GameNight address.');
  }
  final room = (q['r'] ?? fragment['room'])?.toUpperCase();
  final pair = fragment['pair'];
  final seat = int.tryParse(q['seat'] ?? '');
  return HostLink(base,
      roomCode: room != null && isRoomCode(room) ? room : null,
      claim: q['claim'],
      seat: seat,
      linkRevision: int.tryParse(q['link_revision'] ?? '') ?? 0,
      pair: pair != null && pair.isNotEmpty && pair.length <= 200 ? pair : null);
}

/// The link in the sign-in email: `https://gamenight.ontola.io/auth/login#code=12345678`.
/// On Android it opens the app, which finishes the sign-in it started.
class SignInLink {
  final String code;
  const SignInLink(this.code);

  /// Null for any other URL.
  static SignInLink? parse(Uri uri) {
    if (uri.scheme != 'https' || uri.origin != hostedOrigin) return null;
    if (uri.path != '/auth/login') return null;
    final Map<String, String> fragment;
    try {
      fragment = Uri.splitQueryString(uri.fragment);
    } on FormatException {
      return null;
    }
    final code = fragment['code'];
    if (code == null || !RegExp(r'^\d{8}$').hasMatch(code)) return null;
    return SignInLink(code);
  }
}
