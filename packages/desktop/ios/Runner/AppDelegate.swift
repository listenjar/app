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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SharedLinks") {
      SharedLinks.register(with: registrar)
    }
  }
}

/// Links opened with ListenJar, for lib/shared_links.dart: a
/// $(LISTENJAR_URL_SCHEME)://open?url=… link (Info.plist). One that arrives
/// before Dart listens waits until Dart asks for `pending`.
final class SharedLinks: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private let channel: FlutterMethodChannel
  private var pending: [String] = []

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let links = SharedLinks(channel: FlutterMethodChannel(name: "listenjar/links", binaryMessenger: registrar.messenger()))
    // The channel keeps the handler and the handler keeps this, for the
    // app's whole life.
    links.channel.setMethodCallHandler { call, result in
      guard call.method == "pending" else { return result(FlutterMethodNotImplemented) }
      result(links.pending)
      links.pending.removeAll()
    }
    registrar.addSceneDelegate(links)
  }

  // A link that launched the app.
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    connectionOptions?.urlContexts.filter { $0.url.host == "open" }.forEach { open($0.url.absoluteString) }
    return false
  }

  // A link while it runs. Sign-in links are left to signin.dart.
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    let links = URLContexts.filter { $0.url.host == "open" }
    links.forEach { open($0.url.absoluteString) }
    return !links.isEmpty
  }

  private func open(_ link: String) {
    channel.invokeMethod("open", arguments: link) { [weak self] result in
      let missed = result is FlutterError || (result as? NSObject) === FlutterMethodNotImplemented
      if missed { self?.pending.append(link) }
    }
  }
}
