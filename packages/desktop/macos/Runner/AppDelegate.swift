import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    Updates.shared?.addMenuItem()
  }

  // lib/tray.dart: closing the window only hides it, and its Dock icon, so
  // syncing goes on; the menu bar icon quits.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Opening the app again (Finder, Spotlight, the Dock) while it runs hidden
  // brings the window back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showWindow() }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // The sign-in page in the browser opens $(LISTENJAR_URL_SCHEME)://sign-in
  // (Info.plist). LaunchServices activates the app; bring the window back
  // too, even from the Dock. A $(LISTENJAR_URL_SCHEME)://open?url=… link,
  // which the Share menu sends (ShareExtension/), goes on to
  // lib/shared_links.dart.
  override func application(_ application: NSApplication, open urls: [URL]) {
    super.application(application, open: urls)
    urls.filter { $0.host == "open" }.forEach { SharedLinks.shared?.open($0.absoluteString) }
    showWindow()
  }

  private func showWindow() {
    NSApp.setActivationPolicy(.regular)
    if let window = mainFlutterWindow {
      window.deminiaturize(nil)
      window.makeKeyAndOrderFront(nil)
    }
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}

/// Links opened with ListenJar, for lib/shared_links.dart. One that arrives
/// before Dart listens waits until Dart asks for `pending`.
final class SharedLinks {
  /// Made with the window (MainFlutterWindow.swift).
  static var shared: SharedLinks?

  private let channel: FlutterMethodChannel
  private var pending: [String] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "listenjar/links", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pending", let self else { return result(FlutterMethodNotImplemented) }
      result(self.pending)
      self.pending.removeAll()
    }
  }

  func open(_ link: String) {
    channel.invokeMethod("open", arguments: link) { [weak self] result in
      let missed = result is FlutterError || (result as? NSObject) === FlutterMethodNotImplemented
      if missed { self?.pending.append(link) }
    }
  }
}

/// In-app updates with Sparkle, for lib/updates.dart: the appcast at
/// Info.plist's SUFeedURL, whose archives are signed with the Ed25519 key
/// in SUPublicEDKey. Only release packaging sets that key
/// (tool/package-macos.sh), so debug and local builds have no updater, and
/// say so. Sparkle keeps its own preferences in the app's defaults.
final class Updates: NSObject {
  /// Made with the window (MainFlutterWindow.swift).
  static var shared: Updates?

  private let controller: SPUStandardUpdaterController?
  private let channel: FlutterMethodChannel
  private var observations: [NSKeyValueObservation] = []

  init(messenger: FlutterBinaryMessenger) {
    let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
    controller = key.isEmpty
      ? nil
      : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    channel = FlutterMethodChannel(name: "listenjar/updates", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      let updater = self.controller?.updater
      switch call.method {
      case "state":
        result(self.state())
      case "check":
        self.controller?.checkForUpdates(nil)
        result(nil)
      case "setAutomatic":
        updater?.automaticallyChecksForUpdates = call.arguments as? Bool ?? true
        result(self.state())
      case "setAutomaticDownloads":
        updater?.automaticallyDownloadsUpdates = call.arguments as? Bool ?? true
        result(self.state())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // Sparkle's own alert can change these too ("Automatically download and
    // install updates in the future").
    if let updater = controller?.updater {
      observations = [
        updater.observe(\.canCheckForUpdates) { [weak self] _, _ in self?.changed() },
        updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in self?.changed() },
        updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in self?.changed() },
      ]
    }
  }

  private func changed() {
    channel.invokeMethod("changed", arguments: state())
  }

  private func state() -> [String: Any] {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    guard let updater = controller?.updater else { return ["available": false, "version": version] }
    return [
      "available": true,
      "version": version,
      "canCheck": updater.canCheckForUpdates,
      "automatic": updater.automaticallyChecksForUpdates,
      "automaticDownloads": updater.automaticallyDownloadsUpdates,
    ]
  }

  /// "Check for Updates…" under About in the app menu, as Mac apps have it.
  /// Sparkle's controller enables it only while a check can start.
  func addMenuItem() {
    guard let controller, let menu = NSApp.mainMenu?.items.first?.submenu else { return }
    // SPUStandardUpdaterController's checkForUpdates(_:), by name, which
    // tool/swift-check can follow on Linux, where #selector can't.
    let item = NSMenuItem(title: "Check for Updates…", action: NSSelectorFromString("checkForUpdates:"), keyEquivalent: "")
    item.target = controller
    menu.insertItem(item, at: min(1, menu.numberOfItems))
  }
}
