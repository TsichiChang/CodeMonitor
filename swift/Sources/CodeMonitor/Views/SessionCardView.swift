/// A single session tile.
///
/// Flat and airy: a hairline border, with the background tint following live
/// state (green while running, amber while waiting) and pulsing ("breathing")
/// between two tint steps so the state reads at a glance. Waiting breathes
/// faster than running for urgency. Height is fixed regardless of which
/// optional fields a session has, so cards in a row line up.
/// Clicking jumps to the session's terminal.

import SwiftUI

struct SessionCardView: View {
  let session: SessionInfo
  let onFocus: () -> Void

  @Environment(\.colorScheme) private var scheme
  @State private var isHovering = false

  var body: some View {
    Button(action: onFocus) {
      VStack(alignment: .leading, spacing: 8) {
        header
        metaRow
        statusRow
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .modifier(BreathingBackground(state: session.state, scheme: scheme))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(isHovering ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.2))
    )
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .onHover { isHovering = $0 }
    .help("Jump to terminal")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(session.project)
        .font(.body.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      Text(Self.relativeTime(session.lastActivity))
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.tertiary)
    }
  }

  private var metaRow: some View {
    HStack(spacing: 5) {
      if session.gitBranch != nil {
        Image(systemName: "arrow.trianglehead.branch")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      if !metaText.isEmpty {
        Text(metaText)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    // Reserve the row even when empty so cards keep a uniform height.
    .frame(height: 14, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusRow: some View {
    HStack(spacing: 8) {
      StatusPill(state: session.state)
      if let message = session.lastMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var metaText: String {
    [session.gitBranch, session.model.map(Self.shortModel)]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  private static func shortModel(_ model: String) -> String {
    var short = model
    for prefix in ["claude-", "anthropic/"] where short.hasPrefix(prefix) {
      short.removeFirst(prefix.count)
    }
    return short
  }

  static func relativeTime(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date).rounded()))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = Int((Double(seconds) / 60).rounded())
    if minutes < 60 { return "\(minutes)m" }
    let hours = Int((Double(minutes) / 60).rounded())
    if hours < 24 { return "\(hours)h" }
    return "\(Int((Double(hours) / 24).rounded()))d"
  }
}

/// Pulses the card background between two tints of the same hue.
/// Falls back to a static tint when the system asks for reduced motion.
private struct BreathingBackground: ViewModifier {
  let state: SessionState
  let scheme: ColorScheme

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let breath = Palette.breath(for: state, scheme: scheme)
    content.background {
      if let breath, !reduceMotion {
        PhaseAnimator([false, true], trigger: state) { lit in
          Rectangle().fill(lit ? breath.to : breath.from)
        } animation: { _ in
          // The token period covers a full cycle; one phase is half of it.
          .easeInOut(duration: breath.period / 2)
        }
      } else {
        Rectangle().fill(breath?.to ?? Palette.resting(scheme))
      }
    }
  }
}
