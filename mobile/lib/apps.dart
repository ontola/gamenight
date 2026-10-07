import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Installs and opens games' own phone apps. Only Android lets an app do
/// that; elsewhere [supported] is false and the player gets the app from
/// their store.
class Apps {
  static const _channel = MethodChannel('gamenight/apps');

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The installed version, or null when the app is not on this phone.
  static Future<String?> installed(String package) async {
    if (!supported) return null;
    return _channel.invokeMethod<String>('installed', {'package': package});
  }

  static Future<bool> open(String package) async {
    if (!supported) return false;
    return await _channel.invokeMethod<bool>('open', {'package': package}) ?? false;
  }

  /// Whether the player allowed GameNight to install apps.
  static Future<bool> canInstall() async {
    if (!supported) return false;
    return await _channel.invokeMethod<bool>('canInstall') ?? false;
  }

  /// Opens the Android setting that allows GameNight to install apps.
  static Future<void> allowInstalls() => _channel.invokeMethod('allowInstalls');

  /// Downloads the APK at [url] and hands it to Android. Returns once Android
  /// has it; [status] tells how it went from there.
  static Future<void> install(Uri url, String package) =>
      _channel.invokeMethod('install', {'url': url.toString(), 'package': package});

  /// "confirm" while Android asks the player, "done", "failed: ..." or null.
  static Future<String?> status(String package) =>
      _channel.invokeMethod<String>('status', {'package': package});

  /// Opens a store page or other link outside GameNight.
  static Future<void> view(Uri url) => _channel.invokeMethod('view', {'url': url.toString()});
}
