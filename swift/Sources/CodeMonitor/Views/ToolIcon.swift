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
import SwiftUI

/// The tool's mark, at a given size and weight.
///
/// One view for both places that show it — a session card and the quota table.
/// The card had it inline first; a second copy in the header would have been the
/// same fact expressed twice, and this repository has paid for that shape more
/// than once.
struct ToolMark: View {
  let tool: ToolKind
  let size: Double
  /// Colour is earned. An application icon is drawn to win a Dock, so anywhere it
  /// is not the thing being read it goes grey — a folded card, or a quota row
  /// whose job is to be glanced past (ADR-0007).
  var muted = false

  var body: some View {
    Group {
      if let icon = ToolIcon.image(for: tool) {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .saturation(muted ? 0 : 1)
          .opacity(muted ? 0.5 : 1)
      } else {
        // No application installed — the CLIs run without one.
        Image(systemName: tool.symbolName)
          .font(.system(size: size * 0.95))
          .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
      }
    }
    .frame(width: size, height: size)
    .help(tool.label)
  }
}

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
