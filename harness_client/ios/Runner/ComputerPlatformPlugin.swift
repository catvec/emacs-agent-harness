import AVFoundation
import Flutter
import Security
import UIKit

/// What iOS's own frameworks say about a computer registration's
/// permissions, where the app's durable private files are, and how a secret is
/// kept.
///
/// As on Android, nothing here captures anything.  AVFoundation answers the
/// camera and microphone authorization state without prompting; a prompt is
/// made only when the person turns that capability on.  Screen capture has no
/// status to report: ReplayKit can record the app's own content, and sharing
/// the whole device screen needs a broadcast upload extension the app does not
/// ship, so the answer is `broadcast-extension-required` rather than a
/// capability iOS does not give a plain app.
final class ComputerPlatformPlugin: NSObject, FlutterPlugin {
  static let channelName = "app.harness/computer_platform"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(ComputerPlatformPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "permissions":
      result(permissions())
    case "requestPermission":
      guard let name = arguments["name"] as? String else {
        result(FlutterError(code: "bad-argument", message: "name is required", details: nil))
        return
      }
      request(name, result: result)
    case "storageRoot":
      result(storageRoot().path)
    case "secureWrite":
      guard let key = arguments["key"] as? String,
            let value = arguments["value"] as? String else {
        result(FlutterError(code: "bad-arguments", message: "key and value are required", details: nil))
        return
      }
      result(seal(value, account: key))
    case "secureRead":
      guard let key = arguments["key"] as? String else {
        result(FlutterError(code: "bad-arguments", message: "key is required", details: nil))
        return
      }
      result(unseal(account: key))
    case "secureDelete":
      if let key = arguments["key"] as? String { unsealDelete(account: key) }
      result(true)
    case "controlSettings":
      // iOS has no system-wide input-injection service to open settings for.
      result(FlutterError(code: "unsupported", message: "ios-no-system-control", details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// No prompt is made here: these are the states the system already holds.
  private func permissions() -> [String: Any] {
    [
      "sdk": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
      "camera": state(for: .video),
      "microphone": state(for: .audio),
      // ReplayKit records this app's own content; the device screen needs a
      // broadcast upload extension this build does not contain.
      "screen": "unavailable",
      "screenReason": "broadcast-extension-required",
      "screenForegroundService": "unavailable",
      "control": "unavailable",
      "controlReason": "ios-no-system-injection",
    ]
  }

  private func state(for media: AVMediaType) -> String {
    switch AVCaptureDevice.authorizationStatus(for: media) {
    case .authorized: return "available"
    case .denied: return "denied"
    case .restricted: return "unavailable"
    case .notDetermined: return "available"
    @unknown default: return "unavailable"
    }
  }

  private func request(_ name: String, result: @escaping FlutterResult) {
    let media: AVMediaType
    switch name {
    case "camera": media = .video
    case "microphone": media = .audio
    default:
      result(FlutterError(code: "bad-argument", message: "unknown permission \(name)", details: nil))
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: media) {
    case .authorized:
      result("available")
    case .denied, .restricted:
      result("denied")
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: media) { granted in
        DispatchQueue.main.async { result(granted ? "available" : "denied") }
      }
    @unknown default:
      result("unavailable")
    }
  }

  /// The app's own Documents directory, which is private to the app, is
  /// included in its backup, and is not reclaimed the way a cache is.
  private func storageRoot() -> URL {
    let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let root = base.appendingPathComponent("harness-computer", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private let service = "app.harness.computer"

  private func seal(_ value: String, account: String) -> Bool {
    guard let data = value.data(using: .utf8) else { return false }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = data
    // The keychain item is this device's and this app's; it is available
    // after the first unlock so a reconnect after a reboot can read it.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  private func unseal(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func unsealDelete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
