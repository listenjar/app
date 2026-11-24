// Stub: the Sparkle 2 API the macOS runner's Updates uses, as Swift imports
// it (Sparkle.framework/Headers: SPUStandardUpdaterController.h, SPUUpdater.h).
import Cocoa

public protocol SPUUpdaterDelegate: AnyObject {}
public protocol SPUStandardUserDriverDelegate: AnyObject {}

open class SPUUpdater: NSObject {
  open var canCheckForUpdates: Bool { false }
  open var automaticallyChecksForUpdates = false
  open var automaticallyDownloadsUpdates = false
}

open class SPUStandardUpdaterController: NSObject {
  public init(
    startingUpdater: Bool,
    updaterDelegate: SPUUpdaterDelegate?,
    userDriverDelegate: SPUStandardUserDriverDelegate?
  ) {}
  open var updater: SPUUpdater { SPUUpdater() }
  open func checkForUpdates(_ sender: Any?) {}
}
