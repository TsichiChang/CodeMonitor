/// Color-coded live status indicator for a session's state.

import SwiftUI

struct StatusPill: View {
  let state: SessionState

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(Palette.statusColor(state))
        .frame(width: 6, height: 6)
      Text(state.label)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .fixedSize()
  }
}
