import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'avatar.dart';
import 'theme.dart';

/// A small portrait of the actual player, including drawn hats and hair.
class PlayerFaceIcon extends StatelessWidget {
  final Pixels face;
  final String skin;
  const PlayerFaceIcon({super.key, required this.face, required this.skin});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: 30,
        child: CustomPaint(painter: _Portrait(face, hexColor(skin))),
      );
}

class _Portrait extends CustomPainter {
  final Pixels face;
  final Color skin;
  final int revision;
  _Portrait(this.face, this.skin) : revision = Object.hashAll(face);

  @override
  void paint(Canvas canvas, Size size) {
    var bounds = Rect.fromCircle(
        center: const Offset(headX * 1.0, headY * 1.0),
        radius: headRadius * 1.0);
    for (var i = 0; i < face.length; i++) {
      if (face[i] != null) {
        bounds = bounds.expandToInclude(Rect.fromLTWH(
            (i % gridSize).toDouble(), (i ~/ gridSize).toDouble(), 1, 1));
      }
    }
    bounds = bounds.inflate(1);
    final scale =
        math.min(size.width / bounds.width, size.height / bounds.height);
    canvas.save();
    canvas.translate((size.width - bounds.width * scale) / 2,
        (size.height - bounds.height * scale) / 2);
    canvas.scale(scale);
    canvas.translate(-bounds.left, -bounds.top);
    canvas.drawCircle(const Offset(headX * 1.0, headY * 1.0), headRadius * 1.0,
        Paint()..color = skin);
    final pixel = Paint()..isAntiAlias = false;
    for (var i = 0; i < face.length; i++) {
      final color = face[i];
      if (color == null) continue;
      pixel.color = hexColor(color);
      canvas.drawRect(
          Rect.fromLTWH(
              (i % gridSize).toDouble(), (i ~/ gridSize).toDouble(), 1, 1),
          pixel);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Portrait old) =>
      old.revision != revision || old.skin != skin;
}
