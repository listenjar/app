import Cocoa

/// ListenJar in the Share menu (Safari, Chrome, Notes, …). It shows nothing:
/// it opens the app with `$(LISTENJAR_URL_SCHEME)://open?url=…` carrying the
/// shared link or text, and AppDelegate.swift hands that to
/// lib/shared_links.dart, which finds the link in it.
final class ShareViewController: NSViewController {
  override var nibName: NSNib.Name? { nil }

  override func loadView() {
    view = NSView(frame: .zero)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    Task { @MainActor in
      if let shared = await Self.firstLink(in: providers), let url = Self.appLink(for: shared) {
        NSWorkspace.shared.open(url)
      }
      extensionContext?.completeRequest(returningItems: nil)
    }
  }

  /// The first web link shared, else the first text (lib/shared_links.dart
  /// finds a link in "Watch this: https://youtu.be/…").
  private static func firstLink(in providers: [NSItemProvider]) async -> String? {
    for provider in providers where provider.hasItemConformingToTypeIdentifier("public.url") {
      let item = try? await provider.loadItem(forTypeIdentifier: "public.url")
      let url = item as? URL ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
      if let url, !url.isFileURL { return url.absoluteString }
    }
    for provider in providers where provider.hasItemConformingToTypeIdentifier("public.plain-text") {
      if let text = try? await provider.loadItem(forTypeIdentifier: "public.plain-text") as? String {
        return text
      }
    }
    return nil
  }

  /// `<scheme>://open?url=<shared>`, with the scheme from Info.plist. Every
  /// character but the unreserved ones is escaped: Dart reads `+` as a space.
  private static func appLink(for shared: String) -> URL? {
    guard let scheme = Bundle.main.object(forInfoDictionaryKey: "ListenJarURLScheme") as? String,
      let value = shared.addingPercentEncoding(withAllowedCharacters: unreserved)
    else { return nil }
    return URL(string: "\(scheme)://open?url=\(value)")
  }

  private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
