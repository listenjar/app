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
