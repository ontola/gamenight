// The lobby character the face is drawn onto, recoloured like the studio
// preview: the body atlas comes from the host, skin and clothing are tinted,
// the old head is replaced by the shared circular head.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'avatar.dart';

/// Where the 48x48 face grid sits in the 96x80 idle cell.
const Offset faceOrigin = Offset(27, 4);
const Size cellSize = Size(96, 80);

class CharacterSprite {
  static final Map<String, Future<ui.Image?>> _atlas = {};

  /// The raw idle cell from the host, or null when it cannot be loaded.
  static Future<ui.Image?> atlas(Uri url) =>
      _atlas.putIfAbsent(url.toString(), () => _load(url));

  static Future<ui.Image?> _load(Uri url) async {
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final codec = await ui.instantiateImageCodec(response.bodyBytes);
      return (await codec.getNextFrame()).image;
    } catch (_) {
      _atlas.remove(url.toString());
      return null;
    }
  }

  /// Recolours the idle cell. Skin pixels are the cream shades of the atlas.
  static Future<ui.Image> tint(ui.Image atlas, String clothing, String skin) async {
    final w = cellSize.width.toInt(), h = cellSize.height.toInt();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(atlas, Offset.zero, Paint());
    final full = await recorder.endRecording().toImage(w, h);
    final data = (await full.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final rgba = data.buffer.asUint8List();
    List<int> rgb(String hex) =>
        [1, 3, 5].map((i) => int.parse(hex.substring(i, i + 2), radix: 16)).toList();
    final clothes = rgb(clothing), flesh = rgb(skin);
    for (var i = 0; i < rgba.length; i += 4) {
      if (rgba[i + 3] == 0) continue;
      final isSkin = rgba[i] > 200 && rgba[i + 1] > 170 && rgba[i + 2] < rgba[i + 1];
      final shade = isSkin
          ? rgba[i] / 245
          : [rgba[i], rgba[i + 1], rgba[i + 2]].reduce((a, b) => a > b ? a : b) / 255;
      final colour = isSkin ? flesh : clothes;
      for (var c = 0; c < 3; c++) {
        rgba[i + c] = (colour[c] * shade).round().clamp(0, 255);
      }
    }
    // Clear the old head silhouette.
    for (var y = 18; y < 45; y++) {
      for (var x = 34; x < 64; x++) {
        final i = (y * w + x) * 4;
        rgba[i] = rgba[i + 1] = rgba[i + 2] = rgba[i + 3] = 0;
      }
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(Uint8List.fromList(rgba), w, h, ui.PixelFormat.rgba8888,
        completer.complete);
    return completer.future;
  }
}

/// Paints body, head and face at native pixel size, scaled to fit.
class CharacterPainter extends CustomPainter {
  final ui.Image? body;
  final Pixels face;
  final Color skin;
  final int revision;

  CharacterPainter(
      {required this.body, required this.face, required this.skin, this.revision = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = (size.width / cellSize.width) < (size.height / cellSize.height)
        ? size.width / cellSize.width
        : size.height / cellSize.height;
    canvas.translate((size.width - cellSize.width * scale) / 2,
        (size.height - cellSize.height * scale) / 2);
    canvas.scale(scale);
    final pixel = Paint()..isAntiAlias = false;
    if (body != null) {
      canvas.drawImage(body!, Offset.zero, Paint()..filterQuality = FilterQuality.none);
    }
    canvas.drawCircle(faceOrigin + const Offset(headX * 1.0, headY * 1.0), headRadius * 1.0,
        Paint()..color = skin);
    for (var i = 0; i < face.length; i++) {
      final c = face[i];
      if (c == null) continue;
      pixel.color = Color(int.parse(c.substring(1, 7), radix: 16) | 0xFF000000);
      canvas.drawRect(
          Rect.fromLTWH(faceOrigin.dx + i % gridSize, faceOrigin.dy + i ~/ gridSize, 1, 1),
          pixel);
    }
  }

  @override
  bool shouldRepaint(CharacterPainter old) =>
      old.body != body || old.face != face || old.skin != skin || old.revision != revision;
}
