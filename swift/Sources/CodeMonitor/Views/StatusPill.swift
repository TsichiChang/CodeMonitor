/// Color-coded live status indicator for a session's state.

import SwiftUI

struct StatusPill: View {
  let state: SessionState

  @Environment(\.metrics) private var metrics

  var body: some View {
    HStack(spacing: metrics.caption * 0.4) {
      Circle()
        .fill(Palette.statusColor(state))
        .frame(width: metrics.caption * 0.6, height: metrics.caption * 0.6)
      Text(state.label)
        .font(.system(size: metrics.caption, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .fixedSize()
  }
}
