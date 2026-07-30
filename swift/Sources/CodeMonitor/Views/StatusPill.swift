/// Color-coded live status indicator for a session's state.

import SwiftUI

struct StatusPill: View {
  /// The label, not the state. `waiting` has two causes that ask different
  /// things of the user, and the session is what knows which (ADR-0024) — so the
  /// text is decided in one place and handed here rather than re-derived.
  let label: String

  @Environment(\.metrics) private var metrics

  var body: some View {
    // Text alone. The colour is said twice over already — by the dot beside the
    // project name, and by the card's own background, which *is* the state
    // tint. A third copy of it here was the same fact competing with itself.
    Text(label)
      .font(.system(size: metrics.caption, weight: .medium))
      .foregroundStyle(.secondary)
      .fixedSize()
  }
}
