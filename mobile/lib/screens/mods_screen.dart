import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../assistant.dart';
import '../layout.dart';
import '../room_controls.dart';
import '../storage/phone_store.dart';
import '../theme.dart';

/// The games a mod can be made of: Warp games in Luau, which a host copies
/// into the player's drive and Claude changes while they play.
const moddableGames = {'neon-siege-warp': 'Neon Siege'};

String _baseTitle(String base) => moddableGames[base] ?? gameTitle(base);

/// What the room this phone plays in has of a mod right now.
class _Room {
  final Set<String> shelf;
  final String? playing;
  const _Room(this.shelf, this.playing);
  static const none = _Room({}, null);
}

Future<_Room?> _room(AppState state) async {
  final controls = roomControlsFor(state);
  if (controls == null) return null;
  try {
    final games = await controls.games();
    final playlist = await controls.playlist();
    return _Room({for (final g in games) g.id}, playlist.playing);
  } catch (_) {
    return _Room.none;
  }
}

String _status(GameMod mod, _Room? room) {
  if (room == null) return 'Join a room to play it';
  if (room.playing == mod.game) return 'Playing now';
  if (room.shelf.contains(mod.game)) return 'On the shelf';
  return 'Waiting for the host to make it from ${_baseTitle(mod.base)}';
}

/// The player's own mods: copies of a game in their account that Claude
/// changes on request while they play, and that go wherever they sit.
class ModsScreen extends StatefulWidget {
  final AppState state;
  const ModsScreen({super.key, required this.state});

  static Future<void> open(BuildContext context, AppState state) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'mods'),
          builder: (_) => ModsScreen(state: state)));

  @override
  State<ModsScreen> createState() => _ModsScreenState();
}

class _ModsScreenState extends State<ModsScreen> {
  List<GameMod>? _mods;
  _Room? _roomNow;
  String? _error;
  Timer? _timer;

  PhoneStore? get _store => PhoneStore.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh(sync: true));
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool sync = false}) async {
    final store = _store;
    if (store == null || !store.signedIn) return;
    try {
      if (sync) await store.syncNow();
      final mods = await store.mods();
      final room = await _room(widget.state);
      if (!mounted) return;
      setState(() {
        _mods = mods;
        _roomNow = room;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _new() async {
    final made = await showDialog<(String, String)>(
        context: context, builder: (_) => const _NewModDialog());
    final store = _store;
    if (made == null || store == null) return;
    try {
      final id = await store.newMod(made.$1, made.$2);
      await _refresh();
      if (!mounted) return;
      final mod = _mods?.where((m) => m.id == id).firstOrNull;
      if (mod != null) await ModScreen.open(context, widget.state, mod);
      await _refresh();
    } catch (error) {
      if (mounted) toast(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final children = <Widget>[];
    if (store == null) {
      children.add(const Hint(
          'Mods are kept in the GameNight app on your phone or computer, not in the browser.'));
    } else if (!store.signedIn) {
      children.add(const Hint(
          'Sign in to make mods. They are kept in your account, so you can play them wherever you sit.'));
    } else {
      children.add(const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Hint(
            'A mod is your own copy of a game. Play it and tell Claude what should change: '
            'it changes the code while you play, and the mod stays in your account.'),
      ));
      if (_error != null) {
        children.add(Text(_error!, style: const TextStyle(color: GnColors.warn)));
      }
      final mods = _mods;
      if (mods == null) {
        children.add(const Hint('Loading…'));
      } else if (mods.isEmpty) {
        children.add(const Hint('No mods yet.'));
      }
      for (final mod in mods ?? const <GameMod>[]) {
        children.add(Card(
          child: ListTile(
            key: ValueKey('mod-${mod.id}'),
            leading: const Icon(Icons.extension_outlined),
            title: Text(mod.title),
            subtitle: Text(
                'Mod of ${_baseTitle(mod.base)} · ${_status(mod, _roomNow)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await ModScreen.open(context, widget.state, mod);
              await _refresh();
            },
          ),
        ));
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Mods')),
      floatingActionButton: store != null && store.signedIn
          ? FloatingActionButton.extended(
              key: const ValueKey('new-mod'),
              onPressed: _new,
              icon: const Icon(Icons.add),
              label: const Text('New mod'))
          : null,
      body: ContentWidth(
        child: RefreshIndicator(
          onRefresh: () => _refresh(sync: true),
          child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: children),
        ),
      ),
    );
  }
}

class _NewModDialog extends StatefulWidget {
  const _NewModDialog();
  @override
  State<_NewModDialog> createState() => _NewModDialogState();
}

class _NewModDialogState extends State<_NewModDialog> {
  String _base = moddableGames.keys.first;
  late final _name =
      TextEditingController(text: 'My ${_baseTitle(moddableGames.keys.first)}');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New mod'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            initialValue: _base,
            decoration: const InputDecoration(labelText: 'Game'),
            items: [
              for (final e in moddableGames.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value))
            ],
            onChanged: (v) => setState(() => _base = v ?? _base),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('mod-name'),
            controller: _name,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              key: const ValueKey('make-mod'),
              onPressed: () {
                final name = _name.text.trim();
                if (name.isNotEmpty) Navigator.pop(context, (_base, name));
              },
              child: const Text('Make')),
        ],
      );
}

/// One mod: play it, ask for a change while it runs, see what changed,
/// rename or delete it.
class ModScreen extends StatefulWidget {
  final AppState state;
  final GameMod mod;
  const ModScreen({super.key, required this.state, required this.mod});

  static Future<void> open(BuildContext context, AppState state, GameMod mod) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'mod'),
          builder: (_) => ModScreen(state: state, mod: mod)));

  @override
  State<ModScreen> createState() => _ModScreenState();
}

class _ModScreenState extends State<ModScreen> {
  late GameMod _mod = widget.mod;
  _Room? _roomNow;
  final _ask = TextEditingController();
  Timer? _timer;
  bool _starting = false;

  /// The change being made: its request id and when it was asked.
  String? _working;
  String? _error;

  static const _errors = {
    400: 'That request could not be sent. Make it shorter and try again.',
    403: 'Sit in a room (pick up a player) to change your mod.',
    409: 'Your mod is not running right now, or another request is still going.',
    503: 'The assistant is not available right now.',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ask.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final store = PhoneStore.instance;
    if (store == null) return;
    final mods = await store.mods();
    final room = await _room(widget.state);
    final mod = mods.where((m) => m.id == _mod.id).firstOrNull;
    if (!mounted) return;
    setState(() {
      if (mod != null) _mod = mod;
      _roomNow = room;
    });
    if (_working != null) await _check();
  }

  bool get _playing => _roomNow?.playing == _mod.game;

  Future<void> _play() async {
    final controls = roomControlsFor(widget.state);
    if (controls == null) return;
    setState(() => _starting = true);
    try {
      await controls.playNext(_mod.game, start: true);
    } catch (error) {
      if (mounted) toast(context, '$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _send() async {
    final text = _ask.text.trim();
    if (text.isEmpty || _working != null) return;
    final id = assistantId();
    setState(() {
      _working = id;
      _error = null;
    });
    try {
      await widget.state.cloud.request('POST', '/v1/rooms/agent/game',
          body: {'request_id': id, 'game': _mod.game, 'text': text},
          errors: _errors);
    } catch (error) {
      if (mounted) {
        setState(() {
          _working = null;
          _error = error is ApiError ? error.message : '$error';
        });
      }
    }
  }

  /// Whether the change being made is done; when it is, keep it in the mod's
  /// history.
  Future<void> _check() async {
    final id = _working;
    if (id == null) return;
    Map? request;
    try {
      final status =
          await widget.state.cloud.request('GET', '/v1/rooms/agent') as Map;
      request = (status['requests'] as List?)
          ?.whereType<Map>()
          .where((r) => r['id'] == id)
          .firstOrNull;
    } catch (_) {
      return;
    }
    if (request == null || ['thinking', 'queued'].contains(request['state'])) {
      return;
    }
    final change = ModChange(
        at: DateTime.now(),
        asked: request['prompt']?.toString() ?? _ask.text.trim(),
        answer: request['result']?.toString() ?? '',
        ok: request['state'] == 'complete');
    _working = null;
    await PhoneStore.instance?.noteModChange(_mod.id, change);
    if (!mounted) return;
    if (change.ok) _ask.clear();
    setState(() => _error = change.ok ? null : change.answer);
    unawaited(_refresh());
  }

  Future<void> _rename() async {
    final name = TextEditingController(text: _mod.title);
    final title = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Rename mod'),
              content: TextField(
                  controller: name, autofocus: true, maxLength: 80),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, name.text.trim()),
                    child: const Text('Rename')),
              ],
            ));
    name.dispose();
    if (title == null || title.isEmpty || title == _mod.title) return;
    try {
      await PhoneStore.instance?.renameMod(_mod.id, title);
      await _refresh();
    } catch (error) {
      if (mounted) toast(context, '$error');
    }
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('Delete ${_mod.title}?'),
              content: const Text(
                  'It goes off every shelf and out of your account.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: GnColors.danger),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete')),
              ],
            ));
    if (sure != true) return;
    try {
      await PhoneStore.instance?.removeMod(_mod.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) toast(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = _roomNow;
    final onShelf = room?.shelf.contains(_mod.game) ?? false;
    final working = _working != null;
    return Scaffold(
      appBar: AppBar(title: Text(_mod.title), actions: [
        IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _rename),
        IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete),
      ]),
      body: ContentWidth(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Mod of ${_baseTitle(_mod.base)} · ${_status(_mod, room)}',
              style: const TextStyle(color: GnColors.muted)),
          const SizedBox(height: 12),
          if (!_playing && onShelf)
            FilledButton.icon(
                key: const ValueKey('play-mod'),
                onPressed: _starting ? null : _play,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play now')),
          const SizedBox(height: 20),
          const Text('What should change?',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('mod-ask'),
            controller: _ask,
            enabled: !working,
            minLines: 2,
            maxLines: 6,
            maxLength: 2000,
            decoration: const InputDecoration(
                hintText: 'Bosses split in two when they die'),
            onChanged: (_) => setState(() {}),
          ),
          if (!_playing)
            const Hint('Play your mod first: Claude changes it while it runs.'),
          if (working) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Hint(
                'Claude is changing your mod. Each saved file reloads in the game at once, so keep playing.'),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: GnColors.warn)),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
                key: const ValueKey('send-mod-change'),
                onPressed: _playing && !working && _ask.text.trim().isNotEmpty
                    ? _send
                    : null,
                child: const Text('Change it')),
          ),
          if (_mod.changes.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('Changes',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            for (final change in _mod.changes.reversed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    change.ok ? Icons.check_circle_outline : Icons.error_outline,
                    color: change.ok ? GnColors.ok : GnColors.warn),
                title: Text(change.asked),
                subtitle: Text(change.answer),
              ),
          ],
        ]),
      ),
    );
  }
}
