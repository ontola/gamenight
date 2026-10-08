import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../avatar.dart';
import '../character.dart';
import '../faces.dart';
import '../theme.dart';
import 'account_card.dart';
import 'face_editor_screen.dart';

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
  final _body = TintedBody();

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
    _name.dispose();
    super.dispose();
  }

  void _onBody() {
    if (mounted) setState(() {});
  }

  void _onState() {
    _body.update(state.api?.characterSprite, state.clothingColor, state.skinColor);
    if (_name.text != state.name) _name.text = state.name;
  }

  Future<void> _openEditor() async {
    await FaceEditorScreen.open(context, state);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AccountCard(state: state),
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
              body: _body.image,
              face: state.face,
              skin: hexColor(state.skinColor),
              revision: Object.hashAll(state.face)),
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
      ColorSwatches(colors: skinColors, selected: state.skinColor, onTap: state.setSkin),
      const SizedBox(height: 12),
      const Hint('Clothing colour (preview only, games pick their own)'),
      const SizedBox(height: 6),
      ColorSwatches(
          colors: clothingColors, selected: state.clothingColor, onTap: state.setClothing),
    ]);
  }

  /// A preview of the current face. Drawing happens full screen.
  Widget _editor() {
    return Section(title: 'Draw your face', children: [
      const Hint('Draw anywhere on the head, hats included. Tap the canvas to start.'),
      const SizedBox(height: 12),
      Center(
        child: Semantics(
          button: true,
          label: 'Edit face',
          child: GestureDetector(
            onTap: _openEditor,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox.square(
                dimension: 200,
                child: CustomPaint(
                  painter: FaceCanvasPainter(
                    grid: state.face,
                    skin: hexColor(state.skinColor),
                    body: _body.image,
                    guide: true,
                    revision: Object.hashAll(state.face),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Center(
        child: FilledButton.icon(
          onPressed: _openEditor,
          icon: const Icon(Icons.brush, size: 18),
          label: const Text('Edit face'),
        ),
      ),
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
            final data = active ? state.face : art.data;
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
