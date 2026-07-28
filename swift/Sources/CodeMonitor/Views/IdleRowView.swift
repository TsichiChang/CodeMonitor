/// An idle session, collapsed to a line (ADR-0013).
///
/// Not a smaller card — a different shape. Peripheral vision reads shape long
/// before it reads text, so a visibly shorter row says "nothing to do here" at
/// a distance where no label is legible at all. That is also why collapsing is
/// unconditional rather than triggered by running out of room: a session must
/// never change shape because a *different* session appeared, since that
/// relayout is motion carrying no information about anything being looked at.
///
/// Branch, model and the last message are gone here. They are dropped for idle
/// sessions because of state, not because of size — they stay on an active card
/// even on a small screen, and they come back the moment this session acts.

import SwiftUI

struct IdleRowView: View {
  let session: SessionInfo
  let onFocus: () -> Void
  var onDismiss: (() -> Void)?

  @Environment(\.metrics) private var metrics
  @State private var isHovering = false

  var body: some View {
    Button(action: onFocus) {
      HStack(spacing: metrics.cardSpacing) {
        Circle()
          .fill(Color.secondary.opacity(0.7))
          .frame(width: metrics.caption * 0.55, height: metrics.caption * 0.55)

        Text(session.project)
          .font(.system(size: metrics.body * 0.88))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)

        if session.subagentCount > 0 {
          Label("\(session.subagentCount)", systemImage: "circle.hexagongrid")
            .font(.system(size: metrics.caption * 0.9))
            .foregroundStyle(.tertiary)
        }

        Spacer(minLength: metrics.cardSpacing)

        Text(SessionCardView.relativeTime(session.lastActivity))
          .font(.system(size: metrics.caption))
          .monospacedDigit()
          .foregroundStyle(.tertiary)

        // Reserved whether or not it shows, so the elapsed time never shifts
        // sideways on hover.
        dismissButton
          .frame(width: metrics.caption * 1.6)
      }
      .padding(.horizontal, metrics.cardPadding)
      .frame(height: metrics.idleRowHeight)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: metrics.cornerRadius * 0.7)
        .fill(Color.secondary.opacity(isHovering ? 0.10 : 0.04))
    )
    .onHover { isHovering = $0 }
    .help("Jump to terminal")
  }

  @ViewBuilder
  private var dismissButton: some View {
    if let onDismiss, isHovering {
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: metrics.caption * 0.8, weight: .bold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Hide until this session does something new")
      .transition(.opacity)
    } else {
      Color.clear
    }
  }
}
