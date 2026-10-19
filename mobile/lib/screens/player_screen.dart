import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:url_launcher/url_launcher.dart';
import '../app_update.dart';

import '../app_state.dart';
import '../avatar.dart';
import '../character.dart';
import '../theme.dart';
import '../layout.dart';
import 'account_card.dart';
import 'face_editor_screen.dart';

const List<String> clothingColors = [
  '#ff5555',
  '#ff8f3f',
  '#ffc94a',
  '#7ddf64',
  '#3fd0c9',
  '#55a0ff',
  '#8b7bff',
  '#c792ea',
  '#ff7ab8',
  '#b0764a',
  '#9aa5b1',
  '#4a5568',
];

/// Name, face, saved faces and colours. Every change saves by itself.
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
    _body.update(
        state.api?.characterSprite, state.clothingColor, state.skinColor);
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
      builder: (context, _) => ContentWidth(
        maxWidth: 560,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
          children: [
            if (kIsWeb && defaultTargetPlatform == TargetPlatform.android)
              _androidApp(),
            _nameField(),
            const SizedBox(height: 16),
            _character(),
            const SizedBox(height: 24),
            _faces(),
            const SizedBox(height: 24),
            _colors(),
            const SizedBox(height: 24),
            AccountCard(state: state),
          ],
        ),
      ),
    );
  }

  Widget _androidApp() => Section(children: [
        const Row(children: [
          Icon(Icons.android, color: GnColors.ok),
          SizedBox(width: 10),
          Expanded(
              child: Text('Get the Android app',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)))
        ]),
        const SizedBox(height: 8),
        const Hint('Keep GameNight a tap away on your phone.'),
        const SizedBox(height: 12),
        FilledButton.icon(
            onPressed: () async {
              try {
                if (await launchUrl(AppUpdate.apk,
                    mode: LaunchMode.externalApplication)) {
                  return;
                }
              } catch (_) {/* The selectable link remains usable. */}
              if (!mounted) return;
              await showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                          title: const Text('Download the Android app'),
                          content: SelectableText(AppUpdate.apk.toString()),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'))
                          ]));
            },
            icon: const Icon(Icons.download),
            label: const Text('Download APK')),
      ]);

  Widget _nameField() {
    final warn = state.sync == SyncState.warning;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _name,
        maxLength: 20,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
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
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(
          warn
              ? Icons.warning_amber
              : state.sync == SyncState.saving
                  ? Icons.sync
                  : Icons.check,
          size: 14,
          color: warn ? GnColors.warn : GnColors.muted,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            state.syncMessage.isEmpty
                ? 'Saved on this device'
                : state.syncMessage,
            style: TextStyle(
                color: warn ? GnColors.warn : GnColors.muted, fontSize: 12),
          ),
        ),
      ]),
    ]);
  }

  /// Your character as others see it; tapping it draws the face.
  Widget _character() => Column(children: [
        Semantics(
          button: true,
          label: 'Edit face',
          child: GestureDetector(
            onTap: _openEditor,
            child: SizedBox(
              height: 200,
              width: double.infinity,
              child: CustomPaint(
                painter: CharacterPainter(
                    body: _body.image,
                    face: state.face,
                    skin: hexColor(state.skinColor),
                    revision: Object.hashAll(state.face)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _openEditor,
          icon: const Icon(Icons.brush, size: 18),
          label: const Text('Edit face'),
        ),
      ]);

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      );

  /// Every saved face; tap one to wear it, tap the worn one for more.
  Widget _faces() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _heading('Your faces'),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: state.artworks.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              if (i == state.artworks.length) return _newFaceTile();
              final art = state.artworks[i];
              final active = art.id == state.currentArtworkId;
              final data = active ? state.face : art.data;
              return Semantics(
                button: true,
                selected: active,
                label: art.name,
                child: GestureDetector(
                  onTap: () =>
                      active ? _faceActions() : state.selectArtwork(art.id),
                  child: Column(children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: GnColors.bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: active ? GnColors.accent : GnColors.border,
                            width: active ? 3 : 1),
                      ),
                      child: CustomPaint(
                          painter: _FaceThumb(data, state.skinColor)),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 72,
                      child: Text(art.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12,
                              color: active ? Colors.white : GnColors.muted)),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
      ]);

  Widget _newFaceTile() => Semantics(
        button: true,
        label: 'New face',
        child: GestureDetector(
          onTap: () => state.newArtwork(),
          child: Column(children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: GnColors.border),
              ),
              child: const Icon(Icons.add, color: GnColors.muted),
            ),
            const SizedBox(height: 4),
            const Text('New',
                style: TextStyle(fontSize: 12, color: GnColors.muted)),
          ]),
        ),
      );

  Future<void> _faceActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.brush),
              title: const Text('Edit'),
              onTap: () => Navigator.pop(context, 'edit')),
          ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Make a copy'),
              onTap: () => Navigator.pop(context, 'copy')),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(context, 'delete')),
        ]),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'edit':
        await _openEditor();
      case 'copy':
        state.cloneArtwork(state.currentArtworkId);
      case 'delete':
        await _confirmDelete();
    }
  }

  Widget _colors() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _heading('Colours'),
        _colorRow('Skin', skinColors, state.skinColor, state.setSkin),
        _colorRow('Player colour', clothingColors, state.clothingColor,
            state.setClothing,
            hint: 'First to join gets first choice. '
                'Taken colours get a fallback.'),
      ]);

  /// One colour on show; tapping it opens every choice.
  Widget _colorRow(String label, List<String> colors, String selected,
          ValueChanged<String> onPick,
          {String? hint}) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        trailing: Container(
          key: ValueKey('colour-$label'),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: hexColor(selected),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: GnColors.border),
          ),
        ),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    ColorSwatches(
                        colors: colors,
                        selected: selected,
                        wrap: true,
                        size: 44,
                        onTap: (c) {
                          onPick(c);
                          Navigator.pop(context);
                        }),
                    if (hint != null) ...[
                      const SizedBox(height: 12),
                      Hint(hint),
                    ],
                  ]),
            ),
          ),
        ),
      );

  Future<void> _confirmDelete() async {
    final art = state.currentArtwork;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${art.name}?'),
        content: const Text('This face is removed from this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) state.deleteArtwork(art.id);
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
    canvas.drawCircle(Offset((headX + .5) * cell, (headY + .5) * cell),
        headRadius * cell, Paint()..color = hexColor(skin));
    final paint = Paint();
    for (var i = 0; i < face.length; i++) {
      final c = face[i];
      if (c == null) continue;
      paint.color = hexColor(c);
      canvas.drawRect(
          Rect.fromLTWH((i % gridSize) * cell, (i ~/ gridSize) * cell,
              cell + .3, cell + .3),
          paint);
    }
  }

  @override
  bool shouldRepaint(_FaceThumb old) => old.face != face || old.skin != skin;
}
