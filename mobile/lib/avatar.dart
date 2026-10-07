// The face you draw for your player, and its wire format.
//
// Mirrors web/studio.js and crates/gamenight-protocol/src/avatar.rs: a 48x48
// grid, row-major, `null` is transparent, encoded as
// `{"v":1,"w":48,"h":48,"px":[...]}`.
import 'dart:convert';
import 'dart:math';

const int gridSize = 48;

/// Head anchor shared with `Avatar::head_layout` and shared/face.lua.
const int headX = 24, headY = 28, headRadius = 12;

const String _legacyTransparent = '#0f172a';

typedef Pixels = List<String?>;

Pixels emptyFace() => List<String?>.filled(gridSize * gridSize, null);

String encodeAvatar(Pixels px) =>
    jsonEncode({'v': 1, 'w': gridSize, 'h': gridSize, 'px': px});

/// Decodes any avatar the studio ever saved, centring older 16px and 32px
/// drawings the same way the web studio does. Returns null when unreadable.
Pixels? decodeAvatar(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    final o = jsonDecode(text);
    if (o is List) {
      return _normalize(
          o.map((c) => c == _legacyTransparent ? null : c as String?).toList());
    }
    if (o is Map && o['v'] == 1) {
      final px = (o['px'] as List).map((c) => c as String?).toList();
      return _normalize(px, o['w'] as int?, o['h'] as int?);
    }
  } catch (_) {}
  return null;
}

Pixels? _normalize(Pixels px, [int? w, int? h]) {
  final width = w ?? sqrt(px.length).round();
  final height = h ?? width;
  if (width < 1 ||
      height < 1 ||
      width > gridSize ||
      height > gridSize ||
      px.length != width * height) {
    return null;
  }
  final ox = width == 32 ? 14 : width == 16 ? 22 : (gridSize - width) ~/ 2;
  final oy = height == 32 ? 15 : height == 16 ? 23 : (gridSize - height) ~/ 2;
  final out = emptyFace();
  for (var i = 0; i < px.length; i++) {
    out[(oy + i ~/ width) * gridSize + ox + i % width] = px[i];
  }
  return out;
}

/// Four-way flood fill, as in the web studio's bucket tool.
void floodFill(Pixels px, int start, String? replacement) {
  final target = px[start];
  if (target == replacement) return;
  final queue = <int>[start];
  final seen = <int>{};
  while (queue.isNotEmpty) {
    final i = queue.removeLast();
    if (i < 0 || i >= px.length || !seen.add(i) || px[i] != target) continue;
    px[i] = replacement;
    final r = i ~/ gridSize, c = i % gridSize;
    if (r > 0) queue.add(i - gridSize);
    if (r < gridSize - 1) queue.add(i + gridSize);
    if (c > 0) queue.add(i - 1);
    if (c < gridSize - 1) queue.add(i + 1);
  }
}

const String _ink = '#1a1a1a';
const String _white = '#ffffff';

/// A 16x16 sketch pad for the preset faces, placed on the head anchor.
class _Pad {
  final g = List<String?>.filled(16 * 16, null);

  void put(int r, int c, String col) {
    if (r >= 0 && r < 16 && c >= 0 && c < 16) g[r * 16 + c] = col;
  }

  void box(int r0, int r1, int c0, int c1, String col) {
    for (var r = r0; r <= r1; r++) {
      for (var c = c0; c <= c1; c++) {
        put(r, c, col);
      }
    }
  }

  _Pad eyesRound(int row) {
    for (final c in [3, 9]) {
      box(row, row + 2, c, c + 3, _white);
      box(row + 1, row + 2, c + 1, c + 2, _ink);
    }
    return this;
  }

  _Pad eyesDot(int row) {
    box(row, row + 1, 4, 5, _ink);
    box(row, row + 1, 10, 11, _ink);
    return this;
  }

  _Pad eyesWide(int row) {
    for (final c in [3, 9]) {
      box(row, row + 3, c, c + 3, _white);
      box(row + 1, row + 2, c + 1, c + 2, _ink);
    }
    return this;
  }

  _Pad eyesClosed(int row) {
    box(row + 1, row + 1, 3, 6, _ink);
    box(row + 1, row + 1, 9, 12, _ink);
    return this;
  }

  _Pad eyesSquare(int row, [String col = '#5ce1ff']) {
    for (final c in [3, 9]) {
      box(row, row + 3, c, c + 3, _ink);
      box(row + 1, row + 2, c + 1, c + 2, col);
    }
    return this;
  }

  _Pad wink(int row) {
    box(row, row + 2, 3, 6, _white);
    box(row + 1, row + 2, 4, 5, _ink);
    box(row + 1, row + 1, 9, 12, _ink);
    return this;
  }

  _Pad brows(int row) {
    box(row, row, 3, 5, _ink);
    put(row + 1, 6, _ink);
    box(row, row, 10, 12, _ink);
    put(row + 1, 9, _ink);
    return this;
  }

  _Pad starEyes(int row, [String col = '#ffe066']) {
    for (final c in [4, 10]) {
      put(row, c, col);
      box(row + 1, row + 1, c - 1, c + 1, col);
      put(row + 2, c, col);
    }
    return this;
  }

  _Pad eyepatch(int row) {
    box(row, row + 3, 9, 12, _ink);
    box(row - 1, row - 1, 8, 13, _ink);
    box(row, row + 2, 3, 6, _white);
    box(row + 1, row + 2, 4, 5, _ink);
    return this;
  }

  _Pad glasses(int row, [String frame = '#4a5568']) {
    box(row, row + 3, 2, 6, frame);
    box(row + 1, row + 2, 3, 5, _white);
    box(row, row + 3, 9, 13, frame);
    box(row + 1, row + 2, 10, 12, _white);
    box(row + 1, row + 1, 7, 8, frame);
    return this;
  }

  _Pad mouthSmile(int row) {
    box(row, row, 5, 10, _ink);
    put(row - 1, 4, _ink);
    put(row - 1, 11, _ink);
    return this;
  }

  _Pad mouthGrin(int row) {
    box(row, row + 2, 4, 11, _ink);
    box(row + 1, row + 1, 5, 10, _white);
    return this;
  }

  _Pad mouthOpen(int row, [String inner = '#ff7a7a']) {
    box(row, row + 2, 5, 10, _ink);
    box(row + 1, row + 1, 6, 9, inner);
    return this;
  }

  _Pad mouthFrown(int row) {
    box(row + 1, row + 1, 5, 10, _ink);
    put(row, 4, _ink);
    put(row, 11, _ink);
    return this;
  }

  _Pad mouthLine(int row) {
    box(row, row, 6, 9, _ink);
    return this;
  }

  _Pad mouthTongue(int row, [String tongue = '#ff6b9d']) {
    box(row, row, 5, 10, _ink);
    box(row + 1, row + 2, 7, 9, tongue);
    return this;
  }

  _Pad fangs(int row) {
    box(row, row, 4, 11, _ink);
    put(row + 1, 5, _white);
    put(row + 1, 10, _white);
    return this;
  }

  _Pad mouthGrid(int row) {
    for (var c = 5; c <= 10; c += 2) {
      box(row, row + 1, c, c, _ink);
    }
    box(row + 2, row + 2, 5, 10, _ink);
    return this;
  }

  _Pad blush(int row, [String col = '#ff8fa3']) {
    box(row, row + 1, 1, 2, col);
    box(row, row + 1, 13, 14, col);
    return this;
  }

  _Pad freckles(int row, [String col = '#b5651d']) {
    for (final c in [2, 4, 11, 13]) {
      put(row, c, col);
      put(row + 1, c + 1, col);
    }
    return this;
  }

  _Pad antenna([String col = '#9aa5b1', String bulb = '#ff5555']) {
    box(0, 2, 7, 8, col);
    put(0, 7, bulb);
    put(0, 8, bulb);
    return this;
  }

  Pixels done() {
    final face = emptyFace();
    for (var i = 0; i < g.length; i++) {
      final x = headX - 4 + i % 16;
      final y = headY - 7 + i ~/ 16;
      face[y * gridSize + x] = g[i];
    }
    return face;
  }
}

final List<Pixels Function()> _recipes = [
  () => _Pad().eyesRound(5).mouthSmile(11).blush(9).done(),
  () => _Pad().eyesRound(4).mouthGrin(10).done(),
  () => _Pad().eyesClosed(6).mouthLine(11).blush(9).done(),
  () => _Pad().brows(3).eyesDot(5).mouthFrown(11).done(),
  () => _Pad().eyesWide(4).mouthOpen(10).done(),
  () => _Pad().wink(5).mouthTongue(11).blush(9).done(),
  () => _Pad().eyesDot(5).fangs(11).brows(3).done(),
  () => _Pad().eyesRound(5).freckles(9).mouthSmile(12).done(),
  () => _Pad().eyepatch(5).mouthGrin(11).done(),
  () => _Pad().glasses(4).mouthLine(11).freckles(9).done(),
  () => _Pad().starEyes(5).mouthOpen(11).done(),
  () => _Pad().antenna().eyesSquare(5).mouthGrid(11).done(),
];

String _shade(String color) {
  final parts = [1, 3, 5].map((i) =>
      (int.parse(color.substring(i, i + 2), radix: 16) * .72)
          .round()
          .toRadixString(16)
          .padLeft(2, '0'));
  return '#${parts.join()}';
}

/// Adds one hairstyle or hat, keeping the facial features in front.
Pixels _dress(Pixels features, Random rng) {
  T pick<T>(List<T> values) => values[rng.nextInt(values.length)];
  final face = List<String?>.of(features);
  final hair =
      pick(['#30231d', '#6b3926', '#c07832', '#efd078', '#dce3ef', '#8b4dcc']);
  final cloth = pick(['#d64c64', '#437bd1', '#7552b8', '#36a69a', '#e39a36']);
  const cx = headX, bandY = headY - headRadius + 4;
  void box(int x, int y, int w, int h, String color) {
    for (var row = y; row < y + h; row++) {
      for (var col = x; col < x + w; col++) {
        if (row >= 0 && row < gridSize && col >= 0 && col < gridSize) {
          face[row * gridSize + col] = color;
        }
      }
    }
  }

  void dome(String color) {
    box(cx - 6, bandY - 8, 12, 2, color);
    box(cx - 10, bandY - 6, 20, 4, color);
    box(cx - 12, bandY - 2, 24, 4, color);
  }

  final styles = <void Function()>[
    () {
      dome(hair);
      box(cx - 12, bandY + 1, 4, 10, hair);
      box(cx - 8, bandY + 1, 6, 2, hair);
      box(cx - 5, bandY - 6, 1, 5, _shade(hair));
    },
    () {
      for (final x in [cx - 9, cx - 3, cx + 3]) {
        box(x, bandY - 7, 6, 8, hair);
        box(x + 1, bandY - 9, 4, 2, hair);
      }
      box(cx - 12, bandY - 1, 4, 8, hair);
      box(cx + 8, bandY - 1, 4, 8, hair);
    },
    () {
      box(cx - 2, bandY - 13, 4, 13, hair);
      box(cx - 4, bandY - 3, 8, 5, hair);
      box(cx + 1, bandY - 11, 1, 8, _shade(hair));
    },
    () {
      dome(hair);
      box(cx - 12, bandY, 4, 19, hair);
      box(cx + 8, bandY, 4, 19, hair);
      box(cx - 12, bandY + 2, 1, 15, _shade(hair));
    },
    () {
      dome(cloth);
      box(cx - 2, bandY - 12, 4, 4, _white);
      box(cx - 13, bandY, 26, 3, _shade(cloth));
      box(cx - 12, bandY, 24, 1, _white);
    },
    () {
      dome(cloth);
      box(cx + 2, bandY - 5, 3, 3, _white);
      box(cx - 12, bandY, 27, 2, cloth);
      box(cx - 12, bandY + 2, 27, 1, _shade(cloth));
    },
    () {
      for (var y = bandY - 12; y < bandY; y++) {
        final width = 2 + (y - (bandY - 12)) * 2;
        box(cx - width ~/ 2, y, width, 1, cloth);
      }
      box(cx - 13, bandY, 26, 2, cloth);
      box(cx - 13, bandY + 2, 26, 1, _shade(cloth));
      box(cx - 1, bandY - 6, 2, 3, '#ffe066');
    },
    () {
      box(cx - 12, bandY - 2, 24, 5, '#efc448');
      for (final x in [cx - 12, cx - 2, cx + 8]) {
        box(x, bandY - 8, 4, 6, '#efc448');
      }
      box(cx - 12, bandY + 2, 24, 1, '#bd8d27');
      box(cx - 2, bandY - 1, 4, 2, cloth);
    },
  ];
  pick(styles)();
  for (var i = 0; i < features.length; i++) {
    if (features[i] != null) face[i] = features[i];
  }
  return face;
}

int _lastRecipe = -1;

/// A ready-made face, never the same recipe twice in a row.
Pixels randomFace([Random? random]) {
  final rng = random ?? Random();
  var i = rng.nextInt(_recipes.length);
  if (i == _lastRecipe) i = (i + 1 + rng.nextInt(_recipes.length - 1)) % _recipes.length;
  _lastRecipe = i;
  return _dress(_recipes[i](), rng);
}

const List<String> drawPalette = [
  '#ff5555', '#ffaa00', '#ffff55', '#55ff55', '#55ffff', '#5555ff', '#ff55ff',
  '#ffffff', '#c0c0c0', '#808080', '#404040', '#000000',
  '#8b4513', '#ffc0cb', '#7ddf64', '#c792ea',
];

const List<String> skinColors = [
  '#f5e9be', '#f2cfad', '#dfa67f', '#bc805b', '#925c3b',
  '#633d2b', '#ffb7c5', '#8dcdaa', '#9ebfee', '#bba2d9',
];

const String defaultSkin = '#f5e9be';

const List<String> funNames = [
  'Falcon', 'Panda', 'Mango', 'Rocket', 'Disco', 'Waffle', 'Ninja', 'Pickle',
  'Comet', 'Biscuit', 'Tiger', 'Noodle',
];

String randomName([Random? random]) =>
    funNames[(random ?? Random()).nextInt(funNames.length)];
