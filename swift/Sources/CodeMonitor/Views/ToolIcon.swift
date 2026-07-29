/// The icon of the application a tool ships in.
///
/// A card identifies its tool with the icon the user already clicks on, rather
/// than an SF Symbol that has to be learned. Both are needed: the CLIs run on
/// machines with no application installed at all, and there the symbol stands
/// in.
///
/// Looked up once per tool and kept. `NSWorkspace` has to search the Launch
/// Services database to resolve a bundle identifier, which is far too much to
/// repeat inside a view body that SwiftUI re-evaluates on every scan.

import AppKit

@MainActor
enum ToolIcon {
  private static var cache: [ToolKind: NSImage?] = [:]

  static func image(for tool: ToolKind) -> NSImage? {
    if let cached = cache[tool] { return cached }
    let found = lookUp(tool)
    cache[tool] = found
    return found
  }

  private static func lookUp(_ tool: ToolKind) -> NSImage? {
    for identifier in tool.bundleIdentifiers {
      guard
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
      else { continue }
      return NSWorkspace.shared.icon(forFile: url.path)
    }
    return nil
  }
}
