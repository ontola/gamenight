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
  static final _release = Uri.parse(
      'https://github.com/ontola/gamenight/releases/download/app-latest/');
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

/// A strip above the tabs offering the newer APK. The APK downloads in the
/// background first. Once GameNight installed its own previous update,
/// Android 12+ updates it without asking, so it simply installs when the
/// player leaves the app; reopening starts the new version with the same
/// room and seat (both are kept in preferences). Before that, Android shows
/// its own confirmation once.
class UpdateBanner extends StatefulWidget {
  final Future<int?> Function() check;
  final Future<String?> Function(int build) download;
  final Future<bool> Function() silent;
  final Future<void> Function(Uri apk, {bool reopen}) install;

  /// How long GameNight waits in the background before replacing itself,
  /// so a quick look at another app does not close it.
  final Duration backgroundDelay;

  UpdateBanner({
    super.key,
    Future<int?> Function()? check,
    Future<String?> Function(int build)? download,
    Future<bool> Function()? silent,
    Future<void> Function(Uri apk, {bool reopen})? install,
    this.backgroundDelay = const Duration(seconds: 20),
  })  : check = check ??
            (() => Apps.supported ? AppUpdate.newer() : Future.value(null)),
        download = download ??
            ((build) => Apps.download(AppUpdate.apk, 'gamenight-$build.apk')),
        silent = silent ?? Apps.silentSelfUpdate,
        install = install ??
            ((apk, {reopen = false}) =>
                Apps.install(apk, AppUpdate.package, reopen: reopen));

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner>
    with WidgetsBindingObserver {
  static const _recheck = Duration(hours: 6);
  int? _latest;
  Uri? _apk;
  bool _silent = false;
  bool _dismissed = false;
  bool _installing = false;
  DateTime? _checked;
  Timer? _background;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    _background?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Phones keep the app open for days; look again when it comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) {
      if (_apk != null && _silent && !_installing) {
        _background?.cancel();
        _background =
            Timer(widget.backgroundDelay, () => _install(reopen: false));
      }
      return;
    }
    if (s != AppLifecycleState.resumed) return;
    _background?.cancel();
    if (_installing) {
      // Back from Android's dialog without updating (cancelled).
      setState(() => _installing = false);
    } else if (_checked == null ||
        DateTime.now().difference(_checked!) > _recheck) {
      _check();
    }
  }

  Future<void> _check() async {
    _checked = DateTime.now();
    final latest = await widget.check();
    if (!mounted || latest == null || latest == _latest) return;
    // Fetch it now, so the update itself takes no waiting. A failed download
    // still offers the update, downloaded on tap.
    String? path;
    try {
      path = await widget.download(latest);
    } catch (_) {}
    final silent = path != null && await widget.silent();
    if (!mounted) return;
    setState(() {
      _latest = latest;
      _apk = path == null ? null : Uri.file(path);
      _silent = silent;
      _dismissed = false;
    });
  }

  Future<void> _install({required bool reopen}) async {
    if (_installing || !mounted) return;
    if (!_silent && !await Apps.canInstall()) return Apps.allowInstalls();
    setState(() => _installing = true);
    try {
      await widget.install(_apk ?? AppUpdate.apk, reopen: reopen);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _installing = false);
      if (reopen) toast(context, 'Could not update: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_latest == null || _dismissed) return const SizedBox.shrink();
    final message = _installing
        ? (_silent
            ? 'Updating GameNight…'
            : 'Updating GameNight. Android asks you to confirm once.')
        : (_silent
            ? 'New version ready. It installs when you leave GameNight.'
            : 'A new version of GameNight is ready.');
    return Material(
      color: GnColors.button,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            const Icon(Icons.system_update, color: GnColors.text),
            const SizedBox(width: 12),
            Expanded(
                child: Text(message,
                    style: const TextStyle(color: GnColors.text))),
            if (_installing)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else ...[
              TextButton(
                onPressed: () => setState(() => _dismissed = true),
                child: const Text('Later',
                    style: TextStyle(color: GnColors.muted)),
              ),
              TextButton(
                onPressed: () => _install(reopen: true),
                child: Text(_silent ? 'Restart now' : 'Update',
                    style: const TextStyle(
                        color: GnColors.text, fontWeight: FontWeight.bold)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
