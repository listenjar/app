// Stub: the AppKit the macOS runner's AppDelegate uses, as Swift imports it.
@_exported import Foundation

open class NSResponder: NSObject {}

open class NSWindow: NSResponder {
  open func deminiaturize(_ sender: Any?) {}
  open func makeKeyAndOrderFront(_ sender: Any?) {}
}

open class NSApplication: NSResponder {
  public enum ActivationPolicy { case regular, accessory, prohibited }
  @discardableResult open func setActivationPolicy(_ policy: ActivationPolicy) -> Bool { true }
  open func activate() {}
  open func activate(ignoringOtherApps flag: Bool) {}
}

public let NSApp = NSApplication()

public struct Selector {}
public func NSSelectorFromString(_ name: String) -> Selector { Selector() }

open class NSMenuItem: NSObject {
  public init(title: String, action: Selector?, keyEquivalent: String) {}
  open var target: AnyObject?
  open var submenu: NSMenu?
}

open class NSMenu: NSObject {
  open var items: [NSMenuItem] { [] }
  open var numberOfItems: Int { 0 }
  open func insertItem(_ item: NSMenuItem, at index: Int) {}
}

extension NSApplication {
  public var mainMenu: NSMenu? { nil }
}

// Key-value observing, which Foundation has only on Apple platforms.
open class NSKeyValueObservation: NSObject {}
public struct NSKeyValueObservedChange<Value> {}
public protocol KeyValueObservingStub {}
extension NSObject: KeyValueObservingStub {}
extension KeyValueObservingStub where Self: NSObject {
  public func observe<Value>(
    _ keyPath: KeyPath<Self, Value>,
    changeHandler: @escaping (Self, NSKeyValueObservedChange<Value>) -> Void
  ) -> NSKeyValueObservation { NSKeyValueObservation() }
}
