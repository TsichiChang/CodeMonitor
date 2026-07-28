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
  @Environment(\.metrics) private var metrics
  @State private var isHovering = false

  var body: some View {
    Button(action: onFocus) {
      VStack(alignment: .leading, spacing: metrics.cardSpacing) {
        header
        metaRow
        statusRow
      }
      .padding(metrics.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .modifier(BreathingBackground(session: session, scheme: scheme))
    .overlay(
      RoundedRectangle(cornerRadius: metrics.cornerRadius)
        .strokeBorder(
          isHovering ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.2),
          lineWidth: metrics.hairline)
    )
    .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
    .onHover { isHovering = $0 }
    .help("Jump to terminal")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: metrics.cardSpacing) {
      Text(session.project)
        .font(.system(size: metrics.body, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: metrics.cardSpacing * 0.5)
      Text(Self.relativeTime(session.lastActivity))
        .font(.system(size: metrics.caption))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
    }
  }

  private var metaRow: some View {
    HStack(spacing: metrics.cardSpacing * 0.6) {
      if session.gitBranch != nil {
        Image(systemName: "arrow.trianglehead.branch")
          .font(.system(size: metrics.caption * 0.9))
          .foregroundStyle(.tertiary)
      }
      if !metaText.isEmpty {
        Text(metaText)
          .font(.system(size: metrics.caption))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    // Reserve the row even when empty so cards keep a uniform height.
    .frame(height: metrics.caption * 1.4, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusRow: some View {
    HStack(spacing: metrics.cardSpacing) {
      StatusPill(state: session.state)
      if session.subagentCount > 0 {
        Label("\(session.subagentCount)", systemImage: "circle.hexagongrid")
          .font(.system(size: metrics.caption))
          .foregroundStyle(.secondary)
          .help("\(session.subagentCount) sub-agent\(session.subagentCount == 1 ? "" : "s") running under this session")
      }
      if let message = session.lastMessage {
        Text(message)
          .font(.system(size: metrics.caption))
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
  let session: SessionInfo
  let scheme: ColorScheme

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var lit = false

  func body(content: Content) -> some View {
    let breath = Palette.breath(for: session.state, scheme: scheme)
    // A guessed block does not get to pulse. Reported `waiting` means Claude
    // Code fired `PermissionRequest`; inferred means a tool call has been quiet
    // for 45 seconds, and that guess has been wrong (ADR-0012).
    let animates = session.deservesAttention
    content.background {
      if let breath, animates, !reduceMotion {
        Rectangle()
          .fill(lit ? breath.to : breath.from)
          // Scoped to `lit`, deliberately. `PhaseAnimator` was doing this job
          // and its animation applied to everything the redraw touched — so
          // resizing the window animated the card backgrounds' *frames* too,
          // and each one visibly swept out to its new width. Keying the
          // animation to the one value that should animate leaves layout alone.
          //
          // The token period covers a full cycle; one phase is half of it.
          .animation(
            .easeInOut(duration: breath.period / 2).repeatForever(autoreverses: true),
            value: lit
          )
          .onAppear { lit = true }
      } else {
        Rectangle().fill(breath?.to ?? Palette.resting(scheme))
      }
    }
  }
}
