import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Small native hooks (MainActivity.kt / AppDelegate.swift), instead of
/// pulling in wakelock_plus for two calls.
class DeviceChannel {
  DeviceChannel._();
  static const _ch = MethodChannel('ner/device');

  /// Stops the screen from sleeping during turn-by-turn guidance.
  static Future<void> keepScreenOn(bool on) => _call('keepScreenOn', on);

  /// iOS: keep re-downloadable map packs out of iCloud backups.
  static Future<void> excludeFromBackup(String path) => _call('excludeFromBackup', path);

  static Future<void> _call(String method, Object arg) async {
    try {
      await _ch.invokeMethod<void>(method, arg);
    } on MissingPluginException {
      // Tests and unsupported platforms: nothing to do.
    } on PlatformException catch (e) {
      debugPrint('ner/device $method failed: $e');
    }
  }
}
