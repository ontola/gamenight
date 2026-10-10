import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'apps.dart';
import 'theme.dart';

/// This build's number. CI sets it to the Mobile app workflow's run number,
/// the same number as the APK's versionCode. Local builds have 0 and never
/// offer updates.
const appBuild = int.fromEnvironment('GAMENIGHT_BUILD');

/// The signed APK CI publishes on every push to main, next to a
/// `version.json` that names its build number.
class AppUpdate {
  static const package = 'io.ontola.gamenight';
  static final _release = Uri.parse('https://github.com/ontola/gamenight/releases/download/app-latest/');
  static final feed = _release.resolve('version.json');
  static final apk = _release.resolve('gamenight.apk');

  /// The build number of a newer published APK, or null when this one is
  /// current, unknown, or the check failed.
  static Future<int?> newer({int build = appBuild, http.Client? client}) async {
    if (build <= 0) return null;
    try {
      final get = client?.get ?? http.get;
      final response = await get(feed).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final latest = (jsonDecode(response.body) as Map)['build'];
      return latest is int && latest > build ? latest : null;
    } catch (_) {
      return null;
    }
  }
}

/// A strip above the tabs offering the newer APK. Android shows its own
/// confirmation, then replaces and closes this app.
class UpdateBanner extends StatefulWidget {
  final Future<int?> Function() check;
  UpdateBanner({super.key, Future<int?> Function()? check})
      : check = check ?? (() => Apps.supported ? AppUpdate.newer() : Future.value(null));

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> with WidgetsBindingObserver {
  static const _recheck = Duration(hours: 6);
  int? _latest;
  bool _dismissed = false;
  bool _installing = false;
  DateTime? _checked;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Phones keep the app open for days; look again when it comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s != AppLifecycleState.resumed) return;
    if (_installing) {
      // Back from Android's dialog without updating (cancelled).
      setState(() => _installing = false);
    } else if (_checked == null || DateTime.now().difference(_checked!) > _recheck) {
      _check();
    }
  }

  Future<void> _check() async {
    _checked = DateTime.now();
    final latest = await widget.check();
    if (!mounted || latest == null || latest == _latest) return;
    setState(() {
      _latest = latest;
      _dismissed = false;
    });
  }

  Future<void> _update() async {
    if (!await Apps.canInstall()) return Apps.allowInstalls();
    setState(() => _installing = true);
    try {
      await Apps.install(AppUpdate.apk, AppUpdate.package);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _installing = false);
      toast(context, 'Could not update: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_latest == null || _dismissed) return const SizedBox.shrink();
    return Material(
      color: GnColors.button,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            const Icon(Icons.system_update, color: GnColors.text),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _installing ? 'Updating GameNight. Android asks you to confirm.' : 'A new version of GameNight is ready.',
                style: const TextStyle(color: GnColors.text),
              ),
            ),
            if (_installing)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else ...[
              TextButton(
                onPressed: () => setState(() => _dismissed = true),
                child: const Text('Later', style: TextStyle(color: GnColors.muted)),
              ),
              TextButton(
                onPressed: _update,
                child: const Text('Update', style: TextStyle(color: GnColors.text, fontWeight: FontWeight.bold)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
