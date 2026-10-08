import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme.dart';

/// Sign in with a GameNight account: GameNight emails an 8-digit code.
/// Pops with true once signed in.
class SignInScreen extends StatefulWidget {
  final AppState state;

  /// Why the player is asked, e.g. to join a room with its code.
  final String? reason;
  const SignInScreen({super.key, required this.state, this.reason});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late final _email = TextEditingController(text: widget.state.accountEmail ?? '');
  final _code = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_signedInElsewhere);
  }

  /// The link in the email can finish the sign-in while this screen is open.
  void _signedInElsewhere() {
    if (widget.state.signedIn && !_busy && mounted) Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    widget.state.removeListener(_signedInElsewhere);
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
        await widget.state.requestSignInCode(_email.text);
        if (mounted) setState(() => _sent = true);
      });

  Future<void> _verify() => _run(() async {
        final message = await widget.state.verifySignInCode(_code.text);
        if (!mounted) return;
        toast(context, message);
        Navigator.of(context).pop(true);
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Section(title: 'Your GameNight account', children: [
          Hint(widget.reason ??
              'Keep your name and faces on every phone, and join rooms with their code.'),
          if (kIsWeb) ...[
            const SizedBox(height: 8),
            const Hint('Signing in works in the Android and iPhone app. '
                'In a browser, use gamenight.ontola.io.'),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            enabled: !_sent && !_busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Email'),
            onSubmitted: (_) => _send(),
          ),
          const SizedBox(height: 12),
          if (!_sent)
            FilledButton(
              onPressed: _busy ? null : _send,
              child: Text(_busy ? 'Sending…' : 'Email me a code'),
            )
          else ...[
            Hint('We sent an 8-digit code to ${_email.text.trim()}. '
                'It works once and expires in 10 minutes.'),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 8,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 26, letterSpacing: 8, fontFamily: 'monospace'),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(hintText: '········', counterText: ''),
              onChanged: (v) {
                if (v.length == 8) _verify();
              },
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _verify,
              child: Text(_busy ? 'Signing in…' : 'Sign in'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _sent = false;
                        _code.clear();
                      }),
              child: const Text('Use another email or send a new code'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: GnColors.warn)),
          ],
        ]),
      ]),
    );
  }
}
