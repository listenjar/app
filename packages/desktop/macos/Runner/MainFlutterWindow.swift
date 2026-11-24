import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var toast: PasteToast?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Narrower than this, lib/main.dart's top bar and feed rows overflow: a
    // feed's title needs room beside its artwork and "Listen in…".
    contentMinSize = NSSize(width: 520, height: 400)

    // lib/main.dart draws the top bar, link field and all, under the traffic
    // lights: the window's content runs under a see-through titlebar, and an
    // empty unified toolbar makes that titlebar the bar's 52pt.
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    styleMask.insert(.fullSizeContentView)
    let toolbar = NSToolbar(identifier: "ListenJar")
    toolbar.showsBaselineSeparator = false
    self.toolbar = toolbar
    toolbarStyle = .unified

    // Flutter's bar can't move the window itself: it asks, on a drag.
    FlutterMethodChannel(name: "listenjar/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
      .setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "startDrag":
          if let self, let event = self.currentEvent { self.performDrag(with: event) }
          result(nil)
        case "zoom":
          self?.performZoom(nil)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

    // Links opened with the app (AppDelegate.swift).
    SharedLinks.shared = SharedLinks(messenger: flutterViewController.engine.binaryMessenger)

    // The app menu's Settings… (AppDelegate.swift).
    AppMenu.shared = AppMenu(messenger: flutterViewController.engine.binaryMessenger)

    // In-app updates (AppDelegate.swift).
    Updates.shared = Updates(messenger: flutterViewController.engine.binaryMessenger)

    // lib/podcast_apps.dart: "paste the feed link" over another app's window.
    FlutterMethodChannel(name: "listenjar/toast", binaryMessenger: flutterViewController.engine.binaryMessenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "pasteHint",
          let args = call.arguments as? [String: Any],
          let title = args["title"] as? String,
          let message = args["message"] as? String
        else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.toast?.dismiss()
        let toast = PasteToast(title: title, message: message, key: args["key"] as? String ?? "⌘V")
        toast.show(over: args["app"] as? String)
        self?.toast = toast
        result(nil)
      }

    super.awakeFromNib()
  }
}

/// A toast that floats over every app: Podcasts takes a feed only by pasting
/// it into its "Follow a show by URL" box, so this sits right above that box
/// and says the link is on the clipboard. It never takes focus from Podcasts.
final class PasteToast {
  private let panel: NSPanel
  private var poll: Timer?
  private var hide: DispatchWorkItem?

  init(title: String, message: String, key: String) {
    let content = ToastView(title: title, message: message, key: key)
    content.layoutSubtreeIfNeeded()
    panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: content.fittingSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.contentView = content
    content.onClick = { [weak self] in self?.dismiss() }
  }

  /// Waits for [bundleId]'s window to come forward (the link is opening it),
  /// then shows above the box it centres in that window.
  func show(over bundleId: String?) {
    let started = Date()
    poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      guard let bundleId, Date().timeIntervalSince(started) < 4 else {
        timer.invalidate()
        self.present(above: nil)
        return
      }
      guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId,
        frontWindow(of: bundleId) != nil
      else { return }
      timer.invalidate()
      // Let its window and box settle first.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        self.present(above: frontWindow(of: bundleId))
      }
    }
  }

  func dismiss() {
    poll?.invalidate()
    hide?.cancel()
    guard panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.2
      panel.animator().alphaValue = 0
    }, completionHandler: { [panel] in panel.orderOut(nil) })
  }

  private func present(above window: NSRect?) {
    let size = panel.frame.size
    let screen = window.flatMap { w in NSScreen.screens.first { $0.frame.intersects(w) } } ?? NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    var origin: NSPoint
    if let window {
      // Podcasts centres its "Follow a show by URL" box, about 180pt tall,
      // in the window: sit 16pt above it.
      origin = NSPoint(x: window.midX - size.width / 2, y: window.midY + 90 + 16)
    } else {
      origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24)
    }
    origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
    origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)

    // Drifts down onto the box it points at; Reduce Motion only fades.
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    panel.setFrame(NSRect(origin: NSPoint(x: origin.x, y: origin.y + (still ? 0 : 12)), size: size), display: false)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = still ? 0.2 : 0.42
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
      panel.animator().alphaValue = 1
      panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
    }
    if let view = panel.contentView as? ToastView {
      NSAccessibility.post(
        element: view,
        notification: .announcementRequested,
        userInfo: [.announcement: view.spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue]
      )
    }
    let work = DispatchWorkItem { [weak self] in self?.dismiss() }
    hide = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
  }
}

/// [bundleId]'s frontmost ordinary window, in AppKit's screen coordinates.
/// Window bounds need no screen-recording permission; titles would.
private func frontWindow(of bundleId: String) -> NSRect? {
  guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier,
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
  else { return nil }
  let top = NSScreen.screens.first?.frame.maxY ?? 0
  for info in windows {  // front to back
    guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
      (info[kCGWindowLayer as String] as? Int) == 0,
      let dict = info[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
      bounds.width > 300, bounds.height > 300
    else { continue }
    return NSRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
  }
  return nil
}

/// Ink, like ListenJar's dark buttons (lib/theme.dart), with the accent
/// keycap as the one thing to look at.
private final class ToastView: NSView {
  var onClick: (() -> Void)?
  let spoken: String

  private static let ink = NSColor(srgbRed: 0x0A / 255, green: 0x0B / 255, blue: 0x0F / 255, alpha: 1)
  private static let accent = NSColor(srgbRed: 0x51 / 255, green: 0x65 / 255, blue: 0xEE / 255, alpha: 1)

  init(title: String, message: String, key: String) {
    spoken = "\(title). \(message)"
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Self.ink.cgColor
    layer?.cornerRadius = 18
    layer?.cornerCurve = .continuous
    // Holds its edge against a dark window, where the shadow can't.
    layer?.borderWidth = 1
    layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(spoken)

    let keycap = NSView()
    keycap.wantsLayer = true
    keycap.layer?.backgroundColor = Self.accent.cgColor
    keycap.layer?.cornerRadius = 10
    keycap.layer?.cornerCurve = .continuous
    let keyLabel = Self.label(key, size: 15, weight: .semibold, color: .white)
    keycap.addSubview(keyLabel)

    let text = NSStackView(views: [
      Self.label(title, size: 14, weight: .semibold, color: .white),
      Self.label(message, size: 13, weight: .regular, color: NSColor(white: 1, alpha: 0.7)),
    ])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 2

    let row = NSStackView(views: [keycap, text])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 14
    row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 22)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    for view in [keycap, keyLabel] { view.translatesAutoresizingMaskIntoConstraints = false }
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      keycap.widthAnchor.constraint(equalToConstant: 52),
      keycap.heightAnchor.constraint(equalToConstant: 40),
      keyLabel.centerXAnchor.constraint(equalTo: keycap.centerXAnchor),
      keyLabel.centerYAnchor.constraint(equalTo: keycap.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) { onClick?() }

  private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.maximumNumberOfLines = 2
    field.preferredMaxLayoutWidth = 300
    field.setAccessibilityElement(false)
    return field
  }
}
