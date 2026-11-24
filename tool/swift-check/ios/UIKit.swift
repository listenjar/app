// Stub: the UIKit the iOS runner uses, as Swift imports it.
@_exported import Foundation

open class UIResponder: NSObject {}

open class UIApplication: UIResponder {
  public struct LaunchOptionsKey: Hashable { public let rawValue: String }
}

open class UISceneSession: NSObject {}

open class UIOpenURLContext: NSObject {
  public let url: URL
  init(url: URL) { self.url = url }
}

open class UIScene: UIResponder {
  open class ConnectionOptions: NSObject {
    public var urlContexts: Set<UIOpenURLContext> { [] }
  }
}

open class UIWindow: UIResponder {}
