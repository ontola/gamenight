import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../assistant.dart';
import '../layout.dart';
import '../theme.dart';
import '../voice_feedback.dart';
import 'player_screen.dart';

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.state, this.voice});
  final AppState state;
  final VoiceFeedback? voice;
  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen>
    with WidgetsBindingObserver {
  late final Assistant _agent;
  late final VoiceFeedback _voice;
  final _draft = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String _lastHistory = "";
  Timer? _poll;
  (Object, Object?, Object?)? _room;
  String _lastVoice = '';
  bool _voiceOwned = false, _foreground = true;
  Animation<double>? _cover;

  @override
  void initState() {
    super.initState();
    _agent = Assistant(widget.state.cloud)..addListener(_changed);
    _voice = widget.voice ?? VoiceFeedback.instance;
    _voice.addListener(_speechChanged);
    widget.state.addListener(_roomChanged);
    WidgetsBinding.instance.addObserver(this);
    _roomChanged();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_foreground &&
          ModalRoute.of(context)?.isCurrent == true &&
          widget.state.cloud.signedIn) {
        unawaited(_agent.refresh());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.secondaryAnimation;
    if (_cover != animation) {
      _cover?.removeListener(_covered);
      _cover = animation;
      _cover?.addListener(_covered);
    }
  }

  void _covered() {
    if ((_cover?.value ?? 0) > 0 && _voiceOwned) {
      _voiceOwned = false;
      unawaited(_voice.cancel());
    }
  }

  void _roomChanged() {
    final state = widget.state;
    final room =
        (state.cloud.roomIdentity, state.account?.id, state.hostedRoom?.code);
    if (room == _room) return;
    // The account loading in after the screen opened is still the same
    // player at the same table: keep what they already typed.
    final previous = _room;
    final keep = previous != null &&
            previous.$2 == null &&
            previous.$1 == room.$1 &&
            previous.$3 == room.$3
        ? _agent.draft
        : '';
    _room = room;
    if (_voiceOwned) {
      _voiceOwned = false;
      unawaited(_voice.cancel());
    }
    _agent.reset();
    if (keep.isNotEmpty) _agent.setDraft(keep);
    if (state.cloud.signedIn) {
      unawaited(_agent.refresh());
      unawaited(_agent.loadPresets());
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_draft.text != _agent.draft) {
      _draft.value = TextEditingValue(
          text: _agent.draft,
          selection: TextSelection.collapsed(offset: _agent.draft.length));
    }
    final history = jsonEncode(_agent.requests);
    if (history != _lastHistory) {
      _lastHistory = history;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut);
        }
      });
    }
    setState(() {});
  }

  void _speechChanged() {
    if (!mounted || !_voiceOwned || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    if (_voice.text != _lastVoice) {
      _lastVoice = _voice.text;
      _agent.setDraft(_voice.text);
    }
    setState(() {});
  }

  Future<void> _record() async {
    _focus.unfocus();
    _voiceOwned = true;
    _lastVoice = _voice.text;
    if (_voice.listening) {
      await _voice.stop();
    } else {
      await _voice.start(_draft.text);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground && _voiceOwned) {
      _voiceOwned = false;
      unawaited(_voice.cancel());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _cover?.removeListener(_covered);
    widget.state.removeListener(_roomChanged);
    WidgetsBinding.instance.removeObserver(this);
    _voice.removeListener(_speechChanged);
    if (_voiceOwned) unawaited(_voice.cancel());
    _agent.dispose();
    _draft.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<String?> _ask(String title,
      {String initial = '', bool number = false}) async {
    final input = TextEditingController(text: initial);
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(title),
                content: TextField(
                    controller: input,
                    autofocus: true,
                    maxLength: number ? 9 : 60,
                    keyboardType:
                        number ? TextInputType.number : TextInputType.text,
                    onSubmitted: (value) => Navigator.pop(context, value)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, input.text),
                      child: const Text('Save'))
                ]));
    // Dialog's exit animation can still use its text controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    return value;
  }

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(title: Text(title), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Confirm'))
              ])) ??
      false;

  @override
  Widget build(BuildContext context) {
    final signedIn = widget.state.cloud.signedIn;
    final recording = _voiceOwned && (_voice.listening || _voice.busy);
    final controls = _agent.controls;
    return Scaffold(
      appBar: AppBar(title: const Text('Assistant'), actions: [
        IconButton(
            tooltip: 'Refresh Assistant',
            onPressed: _agent.loading || !signedIn
                ? null
                : () {
                    _agent.error = null;
                    unawaited(_agent.refresh());
                    unawaited(_agent.loadPresets());
                  },
            icon: const Icon(Icons.refresh))
      ]),
      body: SafeArea(
          child: ContentWidth(
              maxWidth: 850,
              child: Column(children: [
                Expanded(
                    child: ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                        children: [
                      if (!signedIn) ...[
                        const SizedBox(height: 24),
                        const Icon(Icons.auto_awesome,
                            size: 44, color: GnColors.accent),
                        const SizedBox(height: 16),
                        const Text('Your room, with a little help',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        const Text(
                            'Sign in to ask for games and changes. You can keep playing as a guest.',
                            textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        FilledButton(
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) =>
                                        PlayerScreen(state: widget.state))),
                            child: const Text('Sign in')),
                      ] else ...[
                        if (_agent.status == null && _agent.error == null)
                          const Padding(
                              padding: EdgeInsets.all(24),
                              child:
                                  Center(child: CircularProgressIndicator())),
                        if (controls != null)
                          Row(children: [
                            const Icon(Icons.sports_esports,
                                color: GnColors.ok, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(
                                    gameTitle(controls['game'] as String),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600))),
                            if (widget.state.hostedRoom?.code case final code?)
                              Text(code,
                                  style: const TextStyle(color: GnColors.muted))
                          ]),
                        if (_agent.status != null && !_agent.available)
                          const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Text(
                                  'The AI provider is not configured yet. Game settings and saved configurations are still available.',
                                  style: TextStyle(color: GnColors.warn))),
                        if (_agent.requests.isEmpty && _agent.available) ...[
                          const SizedBox(height: 24),
                          const Text('What shall we change?',
                              style: TextStyle(
                                  fontSize: 26, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          const Text(
                              'Ask for another game, tweak the rules, or try a mod.',
                              style: TextStyle(color: GnColors.muted)),
                          const SizedBox(height: 16),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final prompt in [
                              'Find a co-op game',
                              'Make this easier',
                              'What can we change?'
                            ])
                              ActionChip(
                                  label: Text(prompt),
                                  onPressed:
                                      _agent.busy || _agent.waiting || recording
                                          ? null
                                          : () => _agent.setDraft(prompt))
                          ]),
                        ],
                        if (_agent.status != null) _options(controls),
                        for (final request in _agent.requests.reversed)
                          SelectionArea(child: _message(request)),
                      ],
                      if (signedIn && _agent.status == null && !_agent.loading)
                        TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Back to room')),
                    ])),
                if (signedIn)
                  Container(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      decoration: const BoxDecoration(
                          border:
                              Border(top: BorderSide(color: GnColors.border))),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        if (_agent.error case final error?)
                          _notice(error, error: true),
                        if (_agent.notice.isNotEmpty &&
                            !_agent.requests
                                .any((r) => r['result'] == _agent.notice))
                          _notice(_agent.notice),
                        if (_voiceOwned)
                          if (_voice.error case final error?)
                            _notice(error.replaceAll('feedback', 'request'),
                                error: true),
                        if (recording) ...[
                          Text(_voice.finishing
                              ? 'Finishing…'
                              : _voice.microphoneActive
                                  ? 'Listening…'
                                  : 'Starting microphone…'),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: _voice.soundLevel),
                          const SizedBox(height: 8),
                        ],
                        if (_agent.quote case final quote?)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                  'Up to $quote credits. Unused credits are returned.',
                                  style:
                                      const TextStyle(color: GnColors.warn))),
                        TextField(
                            key: const ValueKey('assistant-draft'),
                            controller: _draft,
                            focusNode: _focus,
                            readOnly: recording || _agent.busy,
                            minLines: 1,
                            maxLines: 4,
                            maxLength: 2000,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(
                                hintText: 'Ask about your game…',
                                counterText: ''),
                            onChanged: (value) {
                              _voice.invalidateResults();
                              _agent.setDraft(value);
                            }),
                        const SizedBox(height: 10),
                        Row(children: [
                          IconButton.filledTonal(
                              tooltip: recording
                                  ? 'Stop recording'
                                  : 'Talk to Assistant',
                              onPressed: _agent.busy ||
                                      _voice.busy ||
                                      !_agent.available ||
                                      _agent.waiting
                                  ? null
                                  : _record,
                              icon: Icon(
                                  recording ? Icons.stop : Icons.mic_none)),
                          const SizedBox(width: 10),
                          Expanded(
                              child: FilledButton.icon(
                                  onPressed: !_agent.canSend || recording
                                      ? null
                                      : () {
                                          _focus.unfocus();
                                          unawaited(_agent.send());
                                        },
                                  icon: _agent.busy || _agent.waiting
                                      ? const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : const Icon(Icons.arrow_upward),
                                  label: Text(_agent.busy
                                      ? 'One moment…'
                                      : _agent.waiting
                                          ? 'Working…'
                                          : _agent.local
                                              ? 'Send'
                                              : _agent.quote == null
                                                  ? 'Review request'
                                                  : 'Send · up to ${_agent.quote} credits'))),
                        ]),
                      ])),
              ]))),
    );
  }

  Widget _notice(String message, {bool error = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Semantics(
          liveRegion: true,
          child: Text(message,
              style:
                  TextStyle(color: error ? GnColors.warn : GnColors.muted))));

  Widget _message(Map<String, dynamic> request) {
    var prompt = request['prompt'] as String? ?? '';
    try {
      final command = jsonDecode(prompt);
      if (command is Map) {
        prompt = switch (command['action']) {
          'undo' => 'Undo change',
          'keep' => 'Keep change',
          'undo_mod' => 'Undo mod',
          'launch' => 'Launch game',
          'set' => 'Apply game settings',
          _ => prompt
        };
      }
    } catch (_) {/* Plain language prompt. */}
    final pending = ['thinking', 'queued'].contains(request['state']);
    final failed =
        ['failed', 'reconciliation_needed'].contains(request['state']);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (request['speaker_name'] case final String name)
                Text(name,
                    style:
                        const TextStyle(color: GnColors.muted, fontSize: 12)),
              const SizedBox(height: 4),
              Text(prompt, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(
                    pending
                        ? Icons.hourglass_top
                        : failed
                            ? Icons.error_outline
                            : Icons.auto_awesome,
                    size: 18,
                    color: failed ? GnColors.warn : GnColors.accent),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(request['result'] as String? ??
                        (request['state'] == 'queued'
                            ? 'Waiting for the game…'
                            : pending
                                ? 'Thinking…'
                                : request['state'].toString())))
              ]),
            ])));
  }

  Widget _options(Map<String, dynamic>? controls) {
    final ready = !_agent.busy && !_agent.waiting;
    return Column(children: [
      if (!_agent.local)
        ExpansionTile(
            title: const Text('Credits and spending'),
            subtitle: Text(
                '${(_agent.status?['credits'] as Map?)?['available'] ?? 0} credits available'),
            children: [
              if (_agent.status?['funding'] case final Map funding)
                Text('${funding['remaining']} credits left in this session')
              else if (_agent.owner)
                TextButton(
                    onPressed: !ready
                        ? null
                        : () async {
                            final input = await _ask(
                                'Session spending limit (credits)',
                                number: true);
                            final cap = int.tryParse(input ?? '');
                            if (mounted && cap != null && cap > 0) {
                              await _agent.fund(cap);
                            }
                          },
                    child: const Text('Set spending limit'))
              else
                const Text('The main player sets the session spending limit.'),
            ]),
      if (controls != null)
        ExpansionTile(
            title: const Text('Game settings'),
            childrenPadding: const EdgeInsets.all(12),
            children: [
              for (final entry in (controls['settings'] as Map? ?? {}).entries)
                ListTile(
                    dense: true,
                    title: Text((entry.value as Map)['label'] as String? ??
                        entry.key.toString()),
                    trailing: Text('${entry.value['value']}')),
              if (_agent.owner)
                Wrap(spacing: 8, children: [
                  if (controls['can_undo'] == true) ...[
                    OutlinedButton(
                        onPressed: ready ? () => _agent.control('undo') : null,
                        child: const Text('Undo change')),
                    OutlinedButton(
                        onPressed: ready ? () => _agent.control('keep') : null,
                        child: const Text('Keep change'))
                  ],
                  if (controls['can_undo_mod'] == true)
                    OutlinedButton(
                        onPressed:
                            ready ? () => _agent.control('undo_mod') : null,
                        child: const Text('Undo mod')),
                  if (controls['launch_players'] case final num players)
                    OutlinedButton(
                        onPressed:
                            ready ? () => _agent.control('launch') : null,
                        child: Text('Play with $players players')),
                ]),
            ]),
      ExpansionTile(
          title: const Text('Saved configurations'),
          childrenPadding: const EdgeInsets.all(12),
          children: [
            if (controls != null)
              TextButton.icon(
                  onPressed: !ready
                      ? null
                      : () async {
                          final name = await _ask('Name this configuration');
                          if (mounted && name != null) {
                            await _agent.savePreset(name);
                          }
                        },
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Save current settings')),
            if (_agent.presets.isEmpty)
              const Text('No saved configurations yet.',
                  style: TextStyle(color: GnColors.muted)),
            for (final preset in _agent.presets)
              ExpansionTile(
                  title: Text(preset['name'] as String),
                  subtitle: Text(gameTitle(preset['game'] as String)),
                  children: [
                    for (final entry
                        in (preset['values'] as Map? ?? {}).entries)
                      ListTile(
                          dense: true,
                          title: Text(((preset['details'] as Map?)?[entry.key]
                                  as Map?)?['label'] as String? ??
                              entry.key.toString()),
                          trailing: Text('${entry.value}')),
                    Wrap(spacing: 8, children: [
                      FilledButton(
                          onPressed: ready &&
                                  _agent.owner &&
                                  preset['game'] == controls?['game']
                              ? () => _agent.applyPreset(preset)
                              : null,
                          child: const Text('Apply')),
                      TextButton(
                          onPressed:
                              !ready || preset['game'] != controls?['game']
                                  ? null
                                  : () async {
                                      if (await _confirm(
                                              'Replace this saved configuration?') &&
                                          mounted) {
                                        await _agent.savePreset(
                                            preset['name'] as String,
                                            id: preset['id'] as String);
                                      }
                                    },
                          child: const Text('Update')),
                      TextButton(
                          onPressed: !ready
                              ? null
                              : () async {
                                  if (await _confirm(
                                          'Delete this configuration?') &&
                                      mounted) {
                                    await _agent
                                        .deletePreset(preset['id'] as String);
                                  }
                                },
                          child: const Text('Delete')),
                    ])
                  ]),
          ]),
    ]);
  }
}
