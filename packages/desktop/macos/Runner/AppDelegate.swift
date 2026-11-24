import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
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
  // too, even from the Dock. A $(LISTENJAR_URL_SCHEME)://open?url=… link
  // goes on to lib/shared_links.dart.
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
