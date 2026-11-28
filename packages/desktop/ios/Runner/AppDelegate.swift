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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LinkScenes") {
      LinkScenes.register(with: registrar)
    }
  }
}

/// Hands links opened with Listenjar, a $(LISTENJAR_URL_SCHEME)://open?url=…
/// link (Info.plist), to SharedLinks.swift. Sign-in links are left to
/// signin.dart.
final class LinkScenes: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  // The registrar may hold its scene delegates weakly.
  private static let shared = LinkScenes()

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.addSceneDelegate(shared)
  }

  // A link that launched the app.
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    connectionOptions?.urlContexts.filter { $0.url.host == "open" }.forEach { SharedLinks.add($0.url.absoluteString) }
    return false
  }

  // A link while it runs.
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    let links = URLContexts.filter { $0.url.host == "open" }
    links.forEach { SharedLinks.add($0.url.absoluteString) }
    return !links.isEmpty
  }
}
