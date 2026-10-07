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
    return Section(title: 'Account', children: [
      if (state.signedIn) ...[
        Row(children: [
          const Icon(Icons.account_circle, color: GnColors.ok),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Signed in${state.accountEmail == null ? '' : ' as ${state.accountEmail}'}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 8),
        Hint('${account?.displayName ?? state.name} and your faces are saved to your account.'),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _signOut,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
        ),
      ] else ...[
        const Hint('Sign in to keep your name and faces on every phone and to join '
            'rooms with their code from anywhere.'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => SignInScreen(state: state))),
          icon: const Icon(Icons.login, size: 18),
          label: const Text('Sign in'),
        ),
      ],
    ]);
  }
}
