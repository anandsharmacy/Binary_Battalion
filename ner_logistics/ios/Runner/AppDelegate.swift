import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Keep-awake during turn-by-turn and iCloud-backup exclusion for
    // re-downloadable map packs (lib/core/platform/device_channel.dart).
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NerDevice") else { return }
    FlutterMethodChannel(name: "ner/device", binaryMessenger: registrar.messenger()).setMethodCallHandler { call, result in
      switch call.method {
      case "keepScreenOn":
        UIApplication.shared.isIdleTimerDisabled = (call.arguments as? Bool) ?? false
        result(nil)
      case "excludeFromBackup":
        guard let path = call.arguments as? String else { result(nil); return }
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try url.setResourceValues(values); result(nil) } catch {
          result(FlutterError(code: "backup", message: "\(error)", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
