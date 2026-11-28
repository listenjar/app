import Foundation

/// Links opened with Listenjar, for lib/shared_links.dart, which calls this
/// through the FFIgen bindings in lib/shared_links_ios.g.dart
/// (tool/ffigen.dart regenerates them from this file). AppDelegate.swift's
/// LinkScenes hands over each link; the links wait here, even from before
/// Dart runs, until Dart takes them, which a ping tells it to do.
///
/// Foundation only, so swiftc can write its Objective-C header on its own.
/// Main thread only: scenes call it there, and so does Dart, whose UI
/// thread is the main thread.
@objc(LJSharedLinks) public final class SharedLinks: NSObject {
  private static var waiting: [String] = []
  private static var arrived: (@convention(c) () -> Void)?

  /// Pings `onArrived` for every link from now on, and once now if any wait.
  /// A C function, not a block: Dart's `NativeCallable.listener` makes one
  /// that may be called from any thread with no trampoline to compile.
  @objc public static func listen(_ onArrived: @convention(c) () -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    arrived = onArrived
    if !waiting.isEmpty { onArrived() }
  }

  /// The links waiting, oldest first, which no longer wait.
  @objc public static func take() -> [String] {
    dispatchPrecondition(condition: .onQueue(.main))
    defer { waiting.removeAll() }
    return waiting
  }

  static func add(_ link: String) {
    dispatchPrecondition(condition: .onQueue(.main))
    waiting.append(link)
    arrived?()
  }
}
