import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../avatar.dart';
import '../character.dart';
import '../faces.dart';
import '../theme.dart';

enum Tool { pencil, eraser, fill }

const List<String> clothingColors = [
  '#ff5555', '#ff8f3f', '#ffc94a', '#7ddf64', '#3fd0c9', '#55a0ff',
  '#8b7bff', '#c792ea', '#ff7ab8', '#b0764a', '#9aa5b1', '#4a5568',
];

/// Name, colours and the face editor. Every change saves by itself.
class PlayerScreen extends StatefulWidget {
  final AppState state;
  const PlayerScreen({super.key, required this.state});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final _name = TextEditingController(text: widget.state.name);
  late Pixels _grid = List.of(widget.state.face);
  final List<Pixels> _undo = [];
  Tool _tool = Tool.pencil;
  String _color = drawPalette.first;
  int _brush = 1;
  bool _guide = true;
  (int, int)? _last;
  bool _strokeDirty = false;
  bool _stroking = false;
  final _canvasKey = GlobalKey();

  ui.Image? _body;
  String? _bodyKey;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.addListener(_refreshBody);
    state.addListener(_followArtwork);
    _refreshBody();
  }

  @override
  void dispose() {
    state.removeListener(_refreshBody);
    state.removeListener(_followArtwork);
    _name.dispose();
    super.dispose();
  }

  Future<void> _refreshBody() async {
    final api = state.api;
    final key = '${api?.base}|${state.clothingColor}|${state.skinColor}';
    if (key == _bodyKey) return;
    _bodyKey = key;
    if (api == null) {
      if (mounted) setState(() => _body = null);
      return;
    }
    final atlas = await CharacterSprite.atlas(api.characterSprite);
    if (atlas == null || key != _bodyKey) return;
    final tinted = await CharacterSprite.tint(atlas, state.clothingColor, state.skinColor);
    if (mounted && key == _bodyKey) setState(() => _body = tinted);
  }

  late String _shownArtwork = state.currentArtworkId;

  /// Picking another saved face (or importing a backup) replaces the canvas.
  void _followArtwork() {
    if (_shownArtwork != state.currentArtworkId) {
      _shownArtwork = state.currentArtworkId;
      setState(() {
        _grid = List.of(state.face);
        _undo.clear();
      });
    }
    if (_name.text != state.name) _name.text = state.name;
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
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _identity(),
          _editor(),
          _gallery(),
          _backup(),
        ],
      ),
    );
  }

  Widget _identity() {
    final warn = state.sync == SyncState.warning;
    return Section(children: [
      SizedBox(
        height: 170,
        child: CustomPaint(
          painter: CharacterPainter(
              body: _body,
              face: _grid,
              skin: hexColor(state.skinColor),
              revision: Object.hashAll(_grid)),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _name,
        maxLength: 20,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          counterText: '',
          hintText: 'Your name',
          prefixIcon: const SizedBox(width: 48),
          suffixIcon: IconButton(
            tooltip: 'Random name',
            icon: const Text('🎲', style: TextStyle(fontSize: 20)),
            onPressed: () {
              final n = randomName();
              _name.text = n;
              state.setName(n);
            },
          ),
        ),
        onChanged: state.setName,
      ),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(
          warn
              ? Icons.warning_amber
              : state.sync == SyncState.saving
                  ? Icons.sync
                  : Icons.check,
          size: 16,
          color: warn ? GnColors.warn : GnColors.ok,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            state.syncMessage.isEmpty ? 'Saved on your phone' : state.syncMessage,
            style: TextStyle(color: warn ? GnColors.warn : GnColors.muted, fontSize: 13),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      const Hint('Skin colour'),
      const SizedBox(height: 6),
      _Swatches(colors: skinColors, selected: state.skinColor, onTap: state.setSkin),
      const SizedBox(height: 12),
      const Hint('Clothing colour (preview only, games pick their own)'),
      const SizedBox(height: 6),
      _Swatches(colors: clothingColors, selected: state.clothingColor, onTap: state.setClothing),
    ]);
  }

  Widget _editor() {
    return Section(title: 'Draw your face', children: [
      const Hint('Draw anywhere on the head, hats included. The circle marks your head.'),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, box) {
        final side = box.maxWidth;
        Offset local(Offset global) =>
            (_canvasKey.currentContext!.findRenderObject() as RenderBox).globalToLocal(global);
        // Claims the pointer at once, so drawing never turns into scrolling.
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
          child: SizedBox(
            key: _canvasKey,
            width: side,
            height: side,
            child: CustomPaint(
              painter: _GridPainter(
                grid: _grid,
                skin: hexColor(state.skinColor),
                body: _guide ? _body : null,
                revision: Object.hashAll(_grid),
              ),
            ),
          ),
        );
      }),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final size in [1, 2, 4, 8])
          ChoiceChip(
            label: Text('$size px'),
            selected: _brush == size,
            onSelected: (_) => setState(() => _brush = size),
          ),
        FilterChip(
          label: const Text('Body guide'),
          selected: _guide,
          onSelected: (v) => setState(() => _guide = v),
        ),
      ]),
      const SizedBox(height: 12),
      _Swatches(
        wrap: true,
        colors: drawPalette,
        selected: _tool == Tool.eraser ? null : _color,
        onTap: (c) => setState(() {
          _color = c;
          if (_tool == Tool.eraser) _tool = Tool.pencil;
        }),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _toolButton(Tool.pencil, '✏️ Draw'),
        _toolButton(Tool.eraser, '🧹 Erase'),
        _toolButton(Tool.fill, '🪣 Fill'),
        OutlinedButton(
          onPressed: _undo.isEmpty
              ? null
              : () {
                  setState(() => _grid = _undo.removeLast());
                  _commit();
                },
          child: const Text('↩️ Undo'),
        ),
        OutlinedButton(onPressed: () => _replace(emptyFace()), child: const Text('🗑️ Clear')),
        OutlinedButton(onPressed: () => _replace(randomFace()), child: const Text('🎲 Random')),
      ]),
    ]);
  }

  Widget _gallery() {
    return Section(title: 'Your faces', children: [
      const Hint('Keep as many faces as you like. Tap one to wear it.'),
      const SizedBox(height: 10),
      SizedBox(
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: state.artworks.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final art = state.artworks[i];
            final active = art.id == state.currentArtworkId;
            final data = active ? _grid : art.data;
            return Semantics(
              button: true,
              selected: active,
              label: art.name,
              child: GestureDetector(
                onTap: () => state.selectArtwork(art.id),
                child: Column(children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: GnColors.bg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: active ? GnColors.accent : GnColors.border, width: active ? 3 : 1),
                    ),
                    child: CustomPaint(painter: _FaceThumb(data, state.skinColor)),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: 72,
                    child: Text(art.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12, color: active ? Colors.white : GnColors.muted)),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
            onPressed: () => state.newArtwork(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New face')),
        OutlinedButton.icon(
            onPressed: () => state.cloneArtwork(state.currentArtworkId),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy')),
        OutlinedButton.icon(
            onPressed: _confirmDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Delete')),
      ]),
    ]);
  }

  Future<void> _confirmDelete() async {
    final art = state.currentArtwork;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${art.name}?'),
        content: const Text('This face is removed from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) state.deleteArtwork(art.id);
  }

  Widget _backup() {
    return Section(title: 'Backup', children: [
      const Hint('Copy your faces, name and skin as text and keep it in a note. '
          'Paste it back here or in the browser studio to restore.'),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.tonalIcon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: state.exportBackup()));
            if (mounted) toast(context, 'Backup copied. Paste it into a note to keep it.');
          },
          icon: const Icon(Icons.content_copy, size: 18),
          label: const Text('Copy backup'),
        ),
        OutlinedButton.icon(
          onPressed: _restore,
          icon: const Icon(Icons.restore, size: 18),
          label: const Text('Restore'),
        ),
      ]),
    ]);
  }

  Future<void> _restore() async {
    final field = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore a backup'),
        content: TextField(
          controller: field,
          maxLines: 6,
          decoration: const InputDecoration(hintText: 'Paste your backup here'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, field.text), child: const Text('Restore')),
        ],
      ),
    );
    field.dispose();
    if (text == null || text.trim().isEmpty || !mounted) return;
    try {
      final added = state.importBackup(text);
      toast(context, 'Imported $added face${added == 1 ? '' : 's'}. Existing faces were kept.');
    } on BackupError catch (e) {
      toast(context, e.message);
    }
  }

  Widget _toolButton(Tool tool, String label) {
    final active = _tool == tool;
    return active
        ? FilledButton(onPressed: () {}, child: Text(label))
        : OutlinedButton(onPressed: () => setState(() => _tool = tool), child: Text(label));
  }
}

class _Swatches extends StatelessWidget {
  final List<String> colors;
  final String? selected;
  final ValueChanged<String> onTap;
  final bool wrap;
  const _Swatches(
      {required this.colors, required this.selected, required this.onTap, this.wrap = false});

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
              width: 34,
              height: 34,
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
    if (wrap) return Wrap(spacing: 8, runSpacing: 8, children: swatches);
    // One swipeable row keeps the drawing grid close to the top.
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: swatches.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => swatches[i],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final Pixels grid;
  final Color skin;
  final ui.Image? body;
  final int revision;
  _GridPainter({required this.grid, required this.skin, required this.body, required this.revision});

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / gridSize;
    canvas.drawRect(Offset.zero & size, Paint()..color = GnColors.canvas);
    canvas.save();
    canvas.scale(cell);
    if (body != null) {
      // The same 48x48 crop of the body the face is drawn onto, dimmed.
      canvas.drawImageRect(
        body!,
        Rect.fromLTWH(faceOrigin.dx, faceOrigin.dy, gridSize.toDouble(), gridSize.toDouble()),
        Rect.fromLTWH(0, 0, gridSize.toDouble(), gridSize.toDouble()),
        Paint()
          ..filterQuality = FilterQuality.none
          ..color = const Color(0x99FFFFFF),
      );
    }
    canvas.drawCircle(const Offset(headX + .0, headY + .0), headRadius + .0,
        Paint()..color = skin);
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
  bool shouldRepaint(_GridPainter old) =>
      old.revision != revision || old.skin != skin || old.body != body || old.grid != grid;
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

/// A saved face on its skin-coloured head, for the gallery.
class _FaceThumb extends CustomPainter {
  final Pixels face;
  final String skin;
  _FaceThumb(this.face, this.skin);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / gridSize;
    canvas.drawCircle(Offset((headX + .5) * cell, (headY + .5) * cell), headRadius * cell,
        Paint()..color = hexColor(skin));
    final paint = Paint();
    for (var i = 0; i < face.length; i++) {
      final c = face[i];
      if (c == null) continue;
      paint.color = hexColor(c);
      canvas.drawRect(
          Rect.fromLTWH((i % gridSize) * cell, (i ~/ gridSize) * cell, cell + .3, cell + .3), paint);
    }
  }

  @override
  bool shouldRepaint(_FaceThumb old) => old.face != face || old.skin != skin;
}
