import 'package:flutter/material.dart';

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
      if (mounted) toast(context, 'Signed out. Your player stays on this phone.');
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = state.account;
    if (state.signedIn) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(children: [
            const Icon(Icons.account_circle, color: GnColors.ok, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(state.accountEmail ?? account?.displayName ?? 'Signed in',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Hint('Your name and faces are saved to your account.'),
              ]),
            ),
            TextButton(onPressed: _busy ? null : _signOut, child: const Text('Sign out')),
          ]),
        ),
      );
    }
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: GnColors.accent, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Sign in to GameNight',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Hint('Keep your name and faces on every phone, and join rooms with their '
              'code from anywhere.'),
          const SizedBox(height: 14),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => SignInScreen(state: state))),
            icon: const Icon(Icons.login, size: 18),
            label: const Text('Sign in with email'),
          ),
        ]),
      ),
    );
  }
}
