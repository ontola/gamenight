import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../app_state.dart';
import '../link.dart';
import '../theme.dart';
import 'scanner_screen.dart';
import 'sign_in_screen.dart';

/// Connect to a GameNight on this network and see where you stand in it.
class RoomScreen extends StatefulWidget {
  final AppState state;
  const RoomScreen({super.key, required this.state});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _rememberJoin = false;
  String? _error;

  AppState get state => widget.state;

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final message = await action();
      if (mounted && message != null) toast(context, message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String text) => _withAccount(() => state.connect(parseHostLink(text)));

  /// Runs [action]; when it needs an account, signs in first and retries.
  Future<void> _withAccount(Future<String> Function() action) => _run(() async {
        try {
          return await action();
        } on ApiError catch (e) {
          if (e != AppState.signInFirst || !mounted) rethrow;
          final ok = await _signIn(
              reason: 'Sign in to join this room. Your name and faces are saved '
                  'to your account and follow you to every GameNight.');
          if (ok != true) return null;
          return action();
        }
      });

  Future<bool?> _signIn({String? reason}) => Navigator.of(context)
      .push<bool>(MaterialPageRoute(builder: (_) => SignInScreen(state: state, reason: reason)));

  Future<void> _scan() async {
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (text != null) await _open(text);
  }

  Future<void> _joinCode() async {
    final code = _code.text.trim().toUpperCase();
    if (!isRoomCode(code)) return;
    // On a GameNight's Wi-Fi the code picks up a character there; otherwise
    // it is an online room, like the website's join page.
    if (state.host != null) {
      await _run(() => state.joinRoom(code, remember: _rememberJoin));
    } else {
      await _withAccount(() => state.joinHostedRoom(code, remember: _rememberJoin));
    }
    _code.clear();
  }

  @override
  Widget build(BuildContext context) {
    final connected = state.host != null;
    return ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                const _Header(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: const TextStyle(color: GnColors.warn)),
                  ),
                if (state.inHostedRoom)
                  ..._hostedCards()
                else if (!connected)
                  ..._connectCards()
                else
                  ..._roomCards(),
              ],
            ));
  }

  Widget _codeField() => TextField(
        controller: _code,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        maxLength: 6,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 28, letterSpacing: 10, fontFamily: 'monospace'),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp('[A-Za-z2-9]')),
          TextInputFormatter.withFunction((_, v) => v.copyWith(text: v.text.toUpperCase())),
        ],
        decoration: const InputDecoration(hintText: '······', counterText: ''),
        onChanged: (v) {
          if (v.length == 6) _joinCode();
        },
      );

  Widget _rememberBox() => CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: _rememberJoin,
        onChanged: (v) => setState(() => _rememberJoin = v ?? false),
        title: const Text('Remember me on this GameNight'),
        controlAffinity: ListTileControlAffinity.leading,
      );

  List<Widget> _hostedCards() {
    final room = state.hostedRoom;
    final connected = room?.connected ?? false;
    final waiting = room?.waiting ?? false;
    return [
      Section(title: room?.code == null ? 'Your room' : 'Room ${room!.code}', children: [
        Row(children: [
          Icon(connected ? Icons.check_circle : Icons.hourglass_top,
              color: connected ? GnColors.ok : GnColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.sessionError ??
                  (room == null
                      ? 'Checking your room…'
                      : connected
                          ? 'Connected as ${state.name}'
                          : waiting
                              ? 'Waiting for pickup in the lobby'
                              : 'Not in a room any more'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Hint(connected
            ? 'Your name and face follow you into every game.'
            : waiting
                ? 'Walk your character to your door in the lobby and stand there to connect.'
                : 'The pickup expired or you left. Enter the room code again.'),
        if (connected) ...[
          const SizedBox(height: 12),
          _Facts(rows: [
            ('Players in the room', '${room!.players}'),
            ('Current game', room.current ?? 'In the lobby'),
            ('Up next', room.next ?? 'No game queued'),
          ]),
          if (!room.fresh)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Hint('The GameNight PC has not checked in for a moment.'),
            ),
        ],
      ]),
      if (room != null && (connected || waiting))
        Section(children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: room.mainPlayer,
            onChanged: _busy
                ? null
                : (v) => _run(() async {
                      await state.setHostedMainPlayer(v);
                      return v
                          ? 'You are the main player on this GameNight.'
                          : 'Your player will no longer appear automatically.';
                    }),
            title: const Text('Main player on this GameNight'),
            subtitle: const Text('Appear at the door on startup, ready for your controller.'),
          ),
          if (!room.mainPlayer)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: room.remembered,
              onChanged: _busy
                  ? null
                  : (v) => _run(() async {
                        await state.setHostedRemember(v);
                        return v
                            ? 'Your player will be waiting here next time.'
                            : 'Your player will no longer be remembered here.';
                      }),
              title: const Text('Remember me on this GameNight'),
            ),
        ]),
      if (room != null && room.none)
        Section(title: 'Room code', children: [_codeField(), _rememberBox()]),
      Section(children: [
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() async {
                    await state.leaveHostedRoom();
                    return waiting
                        ? 'Pickup cancelled.'
                        : 'You left the room. Your player is kept.';
                  }),
          icon: const Icon(Icons.logout, size: 18),
          label: Text(waiting ? 'Cancel pickup' : 'Leave room'),
        ),
      ]),
    ];
  }

  List<Widget> _connectCards() => [
        Section(title: 'Join a room', children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan the QR on the TV'),
          ),
          const SizedBox(height: 20),
          const Center(child: Hint('or enter the room code')),
          const SizedBox(height: 8),
          _codeField(),
        ]),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            title: const Text('Advanced', style: TextStyle(color: GnColors.muted, fontSize: 14)),
            children: [
              TextField(
                controller: _address,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                    labelText: 'GameNight address', hintText: '192.168.1.20:7913'),
                onSubmitted: _busy ? null : _open,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : () => _open(_address.text),
                child: Text(_busy ? 'Connecting…' : 'Connect'),
              ),
              const SizedBox(height: 8),
              const Hint('The address is printed under the QR in the lobby.'),
            ],
          ),
        ),
      ];

  List<Widget> _roomCards() {
    final s = state.session;
    final linked = s?.linked ?? false;
    final waiting = s?.waiting ?? false;
    return [
      Section(title: 'Your session', children: [
        Row(children: [
          Icon(linked ? Icons.check_circle : Icons.link_off,
              color: linked ? GnColors.ok : GnColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.sessionError ??
                  (linked
                      ? 'Signed in as ${s!.playerName ?? state.name}'
                      : waiting
                          ? 'Waiting for pickup in the lobby'
                          : 'Not linked to a character yet'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Hint(linked
            ? '${s!.seat == null ? 'Your profile is linked to this party.' : 'Player ${s.seat! + 1}.'} '
                'Your name and face follow you into every game.'
            : waiting
                ? 'Walk your character to your profile door in the lobby and stand there to connect.'
                : 'Enter the room code from the lobby, or scan the QR above your character.'),
        const SizedBox(height: 12),
        _Facts(rows: [
          ('Players in the party', s == null ? '—' : '${s.players}'),
          (
            'Current game',
            s == null
                ? '—'
                : s.currentTitle == null
                    ? 'In the lobby'
                    : '${s.currentTitle} · ${s.currentPhase}'
          ),
          ('Up next', s == null ? '—' : s.next ?? 'No game queued'),
        ]),
        if (waiting) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      await state.cancelPickup();
                      return 'Pickup cancelled.';
                    }),
            child: const Text('Cancel pickup'),
          ),
        ],
      ]),
      if (!linked && !waiting)
        Section(title: 'Room code', children: [
          _codeField(),
          _rememberBox(),
          const Hint('The first player to join becomes this GameNight’s main player '
              'and returns next time.'),
        ]),
      if (linked || waiting)
        Section(children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: s!.mainPlayer,
            onChanged: _busy
                ? null
                : (v) => _run(() async {
                      await state.setMainPlayer(v);
                      return v
                          ? 'You are the main player on this GameNight.'
                          : 'Your player will no longer appear automatically.';
                    }),
            title: const Text('Main player on this GameNight'),
            subtitle: const Text('Appear at the door on startup, ready for your controller.'),
          ),
          if (!s.mainPlayer)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.remembered,
              onChanged: _busy
                  ? null
                  : (v) => _run(() async {
                        await state.setRemember(v);
                        return v
                            ? 'Your player will be waiting here next time.'
                            : 'Your player will no longer be remembered here.';
                      }),
              title: const Text('Remember me on this GameNight'),
              subtitle: const Text('Return as a guest without becoming the main player.'),
            ),
          if (linked) ...[
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await state.leaveCharacter();
                        return 'You left your character. Your faces stay on this phone.';
                      }),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Leave this character'),
            ),
          ],
        ]),
      Section(children: [
        Row(children: [
          const Icon(Icons.wifi, color: GnColors.muted, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Hint('GameNight at ${state.host!.authority}')),
          TextButton(
            onPressed: _busy ? null : _scan,
            child: const Text('Scan again'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      await state.disconnect();
                      return 'Disconnected. Your player is kept on this phone.';
                    }),
            child: const Text('Leave'),
          ),
        ]),
      ]),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Row(children: [
          GameNightLogo(size: 36),
          SizedBox(width: 10),
          Text('GameNight', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        ]),
      );
}

class _Facts extends StatelessWidget {
  final List<(String, String)> rows;
  const _Facts({required this.rows});
  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Hint(label)),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(value,
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
        ],
      );
}
