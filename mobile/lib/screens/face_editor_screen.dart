import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../avatar.dart';
import '../character.dart';
import '../theme.dart';

enum Tool { pencil, eraser, fill }

/// Whether the body guide is shown, remembered like the web studio's
/// `gamenight_outfit_guide`.
const String guidePref = 'face_guide';

/// Where the eyes and mouth go, as dimmed marks in the guide (web/studio.js).
const List<(int, int)> guideMarks = [
  (24, 26),
  (32, 26),
  (25, 33),
  (26, 33),
  (27, 33),
  (28, 33),
  (29, 33),
  (30, 33),
];
const Color guideMarkColor = Color(0x591E1E28);

/// The full-screen face editor, the app's version of the web studio's
/// "Tap to edit" workspace: the 48x48 canvas as large as fits, with the
/// palette and tools below it. Every stroke saves by itself.
class FaceEditorScreen extends StatefulWidget {
  final AppState state;
  const FaceEditorScreen({super.key, required this.state});

  static Future<void> open(BuildContext context, AppState state) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => FaceEditorScreen(state: state)));

  @override
  State<FaceEditorScreen> createState() => _FaceEditorScreenState();
}

class _FaceEditorScreenState extends State<FaceEditorScreen> {
  late Pixels _grid = List.of(widget.state.face);
  final List<Pixels> _undo = [];
  Tool _tool = Tool.pencil;
  String _color = drawPalette.first;
  int _brush = 1;
  late bool _guide = state.prefs.getBool(guidePref) ?? true;
  (int, int)? _last;
  bool _strokeDirty = false;
  bool _stroking = false;
  final _canvasKey = GlobalKey();
  final _body = TintedBody();
  late String _shownArtwork = state.currentArtworkId;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.addListener(_onState);
    _body.addListener(_onBody);
    _onState();
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    _body.dispose();
    super.dispose();
  }

  void _onBody() {
    if (mounted) setState(() {});
  }

  void _onState() {
    _body.update(state.api?.characterSprite, state.clothingColor, state.skinColor);
    // Restoring a backup can switch faces underneath the editor.
    if (_shownArtwork != state.currentArtworkId) {
      _shownArtwork = state.currentArtworkId;
      _grid = List.of(state.face);
      _undo.clear();
    }
    if (mounted) setState(() {});
  }

  void _setGuide(bool value) {
    setState(() => _guide = value);
    state.prefs.setBool(guidePref, value);
  }

  void _pushUndo() {
    _undo.add(List.of(_grid));
    if (_undo.length > 40) _undo.removeAt(0);
  }

  void _commit() => state.setFace(List.of(_grid));

  void _replace(Pixels next) {
    _pushUndo();
    setState(() => _grid = next);
    _commit();
  }

  void _put(int x, int y, String? color) {
    if (x < 0 || y < 0 || x >= gridSize || y >= gridSize) return;
    final i = y * gridSize + x;
    if (_grid[i] == color) return;
    _grid[i] = color;
    _strokeDirty = true;
  }

  void _stamp(int x, int y) {
    final offset = (_brush - 1) ~/ 2;
    final color = _tool == Tool.eraser ? null : _color;
    for (var dy = 0; dy < _brush; dy++) {
      for (var dx = 0; dx < _brush; dx++) {
        _put(x + dx - offset, y + dy - offset, color);
      }
    }
  }

  void _line((int, int) from, (int, int) to) {
    var (x, y) = from;
    final (ex, ey) = to;
    final dx = (ex - x).abs(), dy = -(ey - y).abs();
    final sx = x < ex ? 1 : -1, sy = y < ey ? 1 : -1;
    var err = dx + dy;
    while (true) {
      _stamp(x, y);
      if (x == ex && y == ey) break;
      final e2 = err * 2;
      if (e2 >= dy) {
        err += dy;
        x += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y += sy;
      }
    }
  }

  void _paintAt(Offset local, double side) {
    final x = (local.dx * gridSize / side).floor();
    final y = (local.dy * gridSize / side).floor();
    if (x < 0 || y < 0 || x >= gridSize || y >= gridSize) {
      _last = null;
      return;
    }
    if (_tool == Tool.fill) {
      if (_last != null) return;
      final before = List.of(_grid);
      floodFill(_grid, y * gridSize + x, _color);
      _strokeDirty = _strokeDirty || before.join() != _grid.join();
    } else {
      _line(_last ?? (x, y), (x, y));
    }
    _last = (x, y);
    setState(() {});
  }

  void _startStroke(Offset p, double side) {
    _pushUndo();
    _strokeDirty = false;
    _last = null;
    _paintAt(p, side);
  }

  void _endStroke() {
    _last = null;
    if (!_strokeDirty) {
      _undo.removeLast();
    } else {
      _commit();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Draw your face'),
          Text(state.currentArtwork.name,
              style: const TextStyle(fontSize: 13, color: GnColors.muted)),
        ]),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth > box.maxHeight * 1.1;
          final canvas = Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, area) =>
                  Center(child: _canvas(min(area.maxWidth, area.maxHeight))),
            ),
          );
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: canvas),
              SizedBox(
                width: min(380, box.maxWidth * .45),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(4, 12, 16, 12),
                  child: _controls(),
                ),
              ),
            ]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: canvas),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight * .55),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _controls(),
              ),
            ),
          ]);
        }),
      ),
    );
  }

  Widget _canvas(double side) {
    Offset local(Offset global) =>
        (_canvasKey.currentContext!.findRenderObject() as RenderBox).globalToLocal(global);
    // Claims the pointer at once, so a stroke never turns into a back swipe.
    return RawGestureDetector(
      gestures: {
        ImmediateMultiDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<ImmediateMultiDragGestureRecognizer>(
          ImmediateMultiDragGestureRecognizer.new,
          (r) => r.onStart = (position) {
            if (_stroking) return null;
            _stroking = true;
            _startStroke(local(position), side);
            return _Stroke(
              onUpdate: (d) => _paintAt(local(d.globalPosition), side),
              onDone: () {
                _stroking = false;
                _endStroke();
              },
            );
          },
        ),
      },
      child: Semantics(
        key: const ValueKey('face-canvas'),
        label: 'Drawing canvas',
        child: SizedBox(
          key: _canvasKey,
          width: side,
          height: side,
          child: CustomPaint(
            painter: FaceCanvasPainter(
              grid: _grid,
              skin: hexColor(state.skinColor),
              body: _body.image,
              guide: _guide,
              revision: Object.hashAll(_grid),
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    const dense = VisualDensity(horizontal: -4, vertical: -4);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ColorSwatches(
        wrap: true,
        size: 32,
        colors: drawPalette,
        selected: _tool == Tool.eraser ? null : _color,
        onTap: (c) => setState(() {
          _color = c;
          if (_tool == Tool.eraser) _tool = Tool.pencil;
        }),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 4, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Padding(
          padding: EdgeInsets.only(right: 2),
          child: Text('Brush', style: TextStyle(color: GnColors.muted, fontSize: 13)),
        ),
        for (final size in [1, 2, 4, 8])
          ChoiceChip(
            visualDensity: dense,
            showCheckmark: false,
            tooltip: '$size px brush',
            label: Text('$size'),
            selected: _brush == size,
            onSelected: (_) => setState(() => _brush = size),
          ),
        const SizedBox(width: 6),
        FilterChip(
          visualDensity: dense,
          showCheckmark: false,
          avatar: Icon(_guide ? Icons.visibility : Icons.visibility_off, size: 18),
          label: const Text('Body guide'),
          selected: _guide,
          onSelected: _setGuide,
        ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        for (final (tool, emoji, label) in [
          (Tool.pencil, '✏️', 'Draw'),
          (Tool.eraser, '🧹', 'Erase'),
          (Tool.fill, '🪣', 'Fill'),
        ])
          _ToolTile(
            emoji: emoji,
            label: label,
            active: _tool == tool,
            onTap: () => setState(() => _tool = tool),
          ),
        _ToolTile(
          emoji: '↩️',
          label: 'Undo',
          onTap: _undo.isEmpty
              ? null
              : () {
                  setState(() => _grid = _undo.removeLast());
                  _commit();
                },
        ),
        _ToolTile(emoji: '🗑️', label: 'Clear', onTap: () => _replace(emptyFace())),
        _ToolTile(emoji: '🎲', label: 'Random', onTap: () => _replace(randomFace())),
      ]),
    ]);
  }
}

/// One button of the toolbar under the canvas: an emoji over a short label.
class _ToolTile extends StatelessWidget {
  final String emoji;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  const _ToolTile({required this.emoji, required this.label, this.active = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Semantics(
          button: true,
          selected: active,
          enabled: enabled,
          child: Material(
            color: active ? GnColors.button : GnColors.field,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: active ? GnColors.accent : GnColors.border),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: Opacity(
                opacity: enabled ? 1 : .4,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    ExcludeSemantics(child: Text(emoji, style: const TextStyle(fontSize: 18))),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(label,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row (or wrapped block) of colour buttons.
class ColorSwatches extends StatelessWidget {
  final List<String> colors;
  final String? selected;
  final ValueChanged<String> onTap;
  final bool wrap;
  final double size;
  const ColorSwatches(
      {super.key,
      required this.colors,
      required this.selected,
      required this.onTap,
      this.wrap = false,
      this.size = 34});

  @override
  Widget build(BuildContext context) {
    final swatches = [
      for (final c in colors)
        Semantics(
          button: true,
          selected: c == selected,
          label: c,
          child: GestureDetector(
            onTap: () => onTap(c),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: hexColor(c),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: c == selected ? Colors.white : GnColors.border,
                  width: c == selected ? 3 : 1,
                ),
              ),
            ),
          ),
        ),
    ];
    if (wrap) return Wrap(spacing: 6, runSpacing: 6, children: swatches);
    return SizedBox(
      height: size,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: swatches.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => swatches[i],
      ),
    );
  }
}

/// The drawing canvas. With the guide on, unpainted cells show the outfit the
/// face is drawn onto (the same 48x48 crop of the body, the round head and
/// marks where eyes and mouth go), like the web studio's outfit guide. With it
/// off they show the skin colour as half-cells, as the web studio does.
class FaceCanvasPainter extends CustomPainter {
  final Pixels grid;
  final Color skin;
  final ui.Image? body;
  final bool guide;
  final int revision;
  FaceCanvasPainter(
      {required this.grid,
      required this.skin,
      required this.body,
      required this.guide,
      required this.revision});

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / gridSize;
    canvas.drawRect(Offset.zero & size, Paint()..color = GnColors.canvas);
    canvas.save();
    canvas.scale(cell);
    if (guide) {
      if (body != null) {
        canvas.drawImageRect(
          body!,
          Rect.fromLTWH(faceOrigin.dx, faceOrigin.dy, gridSize.toDouble(), gridSize.toDouble()),
          Rect.fromLTWH(0, 0, gridSize.toDouble(), gridSize.toDouble()),
          Paint()..filterQuality = FilterQuality.none,
        );
      }
      canvas.drawCircle(
          const Offset(headX + .0, headY + .0), headRadius + .0, Paint()..color = skin);
      final mark = Paint()
        ..color = guideMarkColor
        ..isAntiAlias = false;
      for (final (x, y) in guideMarks) {
        canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), mark);
      }
    } else {
      final halves = Path();
      for (var y = 0; y < gridSize; y++) {
        for (var x = 0; x < gridSize; x++) {
          halves
            ..moveTo(x.toDouble(), y.toDouble())
            ..lineTo(x + 1.0, y.toDouble())
            ..lineTo(x.toDouble(), y + 1.0)
            ..close();
        }
      }
      canvas.drawPath(halves, Paint()..color = skin);
    }
    final p = Paint()..isAntiAlias = false;
    for (var i = 0; i < grid.length; i++) {
      final c = grid[i];
      if (c == null) continue;
      p.color = hexColor(c);
      canvas.drawRect(Rect.fromLTWH((i % gridSize) - .02, (i ~/ gridSize) - .02, 1.04, 1.04), p);
    }
    canvas.restore();
    final line = Paint()
      ..color = const Color(0x22FFFFFF)
      ..strokeWidth = 1;
    for (var i = 0; i <= gridSize; i += 4) {
      final o = i * cell;
      canvas.drawLine(Offset(o, 0), Offset(o, size.height), line);
      canvas.drawLine(Offset(0, o), Offset(size.width, o), line);
    }
  }

  @override
  bool shouldRepaint(FaceCanvasPainter old) =>
      old.revision != revision ||
      old.skin != skin ||
      old.body != body ||
      old.guide != guide ||
      old.grid != grid;
}

class _Stroke extends Drag {
  final GestureDragUpdateCallback onUpdate;
  final VoidCallback onDone;
  _Stroke({required this.onUpdate, required this.onDone});
  @override
  void update(DragUpdateDetails details) => onUpdate(details);
  @override
  void end(DragEndDetails details) => onDone();
  @override
  void cancel() => onDone();
}
