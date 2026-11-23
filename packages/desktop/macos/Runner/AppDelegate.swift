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
  // too, even from the Dock.
  override func application(_ application: NSApplication, open urls: [URL]) {
    super.application(application, open: urls)
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
