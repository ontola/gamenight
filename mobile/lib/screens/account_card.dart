import 'package:flutter/material.dart';

import '../api.dart' show ApiError;
import '../app_state.dart';
import '../theme.dart';
import 'sign_in_screen.dart';

/// Sign in or out of a GameNight account, on the You tab.
class AccountCard extends StatefulWidget {
  final AppState state;
  const AccountCard({super.key, required this.state});

  @override
  State<AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<AccountCard> {
  bool _busy = false;

  AppState get state => widget.state;

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await state.signOut();
      if (mounted) {
        toast(context, 'Signed out. Your player stays on this phone.');
      }
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeEmail() async {
    final email = await showDialog<String>(
        context: context, builder: (_) => _ChangeEmailDialog(state: state));
    if (mounted && email != null) toast(context, 'You now sign in with $email');
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Delete your account?'),
              content: const Text(
                  'Your saved player, faces, likes, play history and purchases are removed from GameNight for good. The player on this device stays.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Keep account')),
                FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: GnColors.danger),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete account')),
              ],
            ));
    if (sure != true) return;
    setState(() => _busy = true);
    try {
      await state.deleteAccount();
      if (mounted) toast(context, 'Your account is deleted.');
    } catch (e) {
      if (mounted) toast(context, e is ApiError ? e.message : e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = state.account;
    if (state.signedIn) {
      final email = account?.email ?? state.accountEmail;
      return Section(title: 'Account', children: [
        Row(children: [
          const Icon(Icons.mail_outline, color: GnColors.muted, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(email ?? 'Signed in',
                  key: const ValueKey('account-email'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const Hint('You sign in with this email.'),
            ]),
          ),
          TextButton(
              onPressed: _busy ? null : _changeEmail,
              child: const Text('Change')),
        ]),
        const SizedBox(height: 8),
        const Hint('Your name and faces are saved to your account.'),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: _busy ? null : _signOut,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Sign out')),
          TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: GnColors.danger),
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete account')),
        ]),
      ]);
    }
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: GnColors.accent, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Save your player',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Hint(
              'Optional: keep your name and faces for next time. You can play without an account.'),
          const SizedBox(height: 14),
          FilledButton.icon(
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => SignInScreen(state: state))),
            icon: const Icon(Icons.login, size: 18),
            label: const Text('Sign in with email'),
          ),
        ]),
      ),
    );
  }
}

/// Two steps: a new address, then the code GameNight mailed to it.
class _ChangeEmailDialog extends StatefulWidget {
  final AppState state;
  const _ChangeEmailDialog({required this.state});

  @override
  State<_ChangeEmailDialog> createState() => _ChangeEmailDialogState();
}

class _ChangeEmailDialogState extends State<_ChangeEmailDialog> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  String? _request, _error;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final request = _request;
      if (request == null) {
        final sent = await widget.state.requestEmailChange(_email.text);
        if (mounted) setState(() => _request = sent);
      } else {
        await widget.state.confirmEmailChange(request, _code.text);
        if (mounted) Navigator.pop(context, widget.state.accountEmail);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sent = _request != null;
    return AlertDialog(
      title: const Text('Change email'),
      content: SizedBox(
        width: 360,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Hint(sent
                  ? 'We sent a code to ${_email.text.trim()}. Enter it to switch.'
                  : 'We send a code to the new address to check it is yours.'),
              const SizedBox(height: 16),
              if (!sent)
                TextField(
                  controller: _email,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'New email'),
                  onSubmitted: _busy ? null : (_) => _submit(),
                )
              else
                TextField(
                  controller: _code,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration: const InputDecoration(
                      labelText: 'Code from the email', counterText: ''),
                  onSubmitted: _busy ? null : (_) => _submit(),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: GnColors.warn)),
              ],
            ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(sent ? 'Confirm' : 'Send code')),
      ],
    );
  }
}
