/// Color-coded live status indicator for a session's state.

import SwiftUI

struct StatusPill: View {
  let state: SessionState

  @Environment(\.metrics) private var metrics

  var body: some View {
    // Text alone. The colour is said twice over already — by the dot beside the
    // project name, and by the card's own background, which *is* the state
    // tint. A third copy of it here was the same fact competing with itself.
    Text(state.label)
      .font(.system(size: metrics.caption, weight: .medium))
      .foregroundStyle(.secondary)
      .fixedSize()
  }
}
