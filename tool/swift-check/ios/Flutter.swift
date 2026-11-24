// Stub: the Flutter iOS embedder API the runner uses, as Swift imports it
// (engine/src/flutter/shell/platform/darwin/ios/framework/Headers).
import Foundation
import UIKit

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

// Optional in Objective-C.
public protocol FlutterSceneLifeCycleDelegate: AnyObject {
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?) -> Bool
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool
}
extension FlutterSceneLifeCycleDelegate {
  public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?) -> Bool { false }
  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool { false }
}

public protocol FlutterPluginRegistrar: AnyObject {
  func messenger() -> FlutterBinaryMessenger
  func addSceneDelegate(_ delegate: FlutterSceneLifeCycleDelegate)
}

public protocol FlutterPlugin: AnyObject {
  static func register(with registrar: FlutterPluginRegistrar)
}

public protocol FlutterPluginRegistry: AnyObject {
  func registrar(forPlugin pluginKey: String) -> FlutterPluginRegistrar?
}

public protocol FlutterImplicitEngineBridge: AnyObject {
  var pluginRegistry: FlutterPluginRegistry { get }
}

public protocol FlutterImplicitEngineDelegate: AnyObject {
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge)
}

open class FlutterAppDelegate: UIResponder {
  public required override init() {}
  open func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
  // @main's entry point, which UIApplicationMain provides on iOS.
  public static func main() {}
}

open class FlutterSceneDelegate: UIResponder {
  open var window: UIWindow?
}

// Generated into ios/Runner by flutter.
public enum GeneratedPluginRegistrant {
  public static func register(with registry: FlutterPluginRegistry) {}
}
