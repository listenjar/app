// Stub: the Flutter macOS embedder API the runner's AppDelegate uses, as
// Swift imports it (engine/src/flutter/shell/platform/darwin/macos).
@_exported import Cocoa
import Foundation

public typealias FlutterResult = (Any?) -> Void
public typealias FlutterMethodCallHandler = (FlutterMethodCall, @escaping FlutterResult) -> Void
public let FlutterMethodNotImplemented = NSObject()

open class FlutterError: NSObject {}

open class FlutterMethodCall: NSObject {
  public var method: String { "" }
  public var arguments: Any? { nil }
}

public protocol FlutterBinaryMessenger: AnyObject {}

open class FlutterMethodChannel: NSObject {
  public init(name: String, binaryMessenger messenger: FlutterBinaryMessenger) {}
  open func setMethodCallHandler(_ handler: FlutterMethodCallHandler?) {}
  open func invokeMethod(_ method: String, arguments: Any?) {}
  open func invokeMethod(_ method: String, arguments: Any?, result callback: FlutterResult?) {}
}

open class FlutterAppDelegate: NSResponder {
  public required override init() {}
  open var mainFlutterWindow: NSWindow?
  // Swift sees this optional NSApplicationDelegate method, but
  // FlutterAppDelegate.mm doesn't implement it: a super call throws.
  open func applicationDidFinishLaunching(_ notification: Notification) {}
  open func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  open func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
  open func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
  open func application(_ application: NSApplication, open urls: [URL]) {}
  // @main's entry point, which NSApplicationMain provides on macOS.
  public static func main() {}
}
