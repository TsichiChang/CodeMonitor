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
  /// Present only for sessions the user is allowed to close.
  var onDismiss: (() -> Void)?

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
    .overlay(alignment: .topTrailing) { dismissButton }
    .onHover { isHovering = $0 }
    .help("Jump to terminal")
  }

  /// Shown on hover only. A card that is always wearing a close button invites
  /// being tidied away; this one has to be reached for.
  @ViewBuilder
  private var dismissButton: some View {
    if let onDismiss, isHovering {
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.secondary)
          .padding(4)
          .background(Circle().fill(.background.opacity(0.75)))
      }
      .buttonStyle(.plain)
      .padding(5)
      .help("Hide until this session does something new")
      .transition(.opacity)
    }
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
  /// The state being painted underneath while the new one wipes across.
  @State private var outgoing: SessionState?
  /// How far the new state has swept, 0…1 from the leading edge.
  @State private var sweep: CGFloat = 1

  private static let sweepDuration: Double = 0.55

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          // The state being replaced stays put and is wiped over, so the change
          // reads as one colour advancing across the card rather than the whole
          // card blinking.
          if let outgoing, sweep < 1 {
            fill(for: outgoing, animated: false)
          }
          fill(for: state, animated: true)
            .mask(alignment: .leading) {
              Rectangle().scaleEffect(x: sweep, y: 1, anchor: .leading)
            }
        }
      }
      .onChange(of: state) { previous, _ in
        guard !reduceMotion else { return }
        outgoing = previous
        sweep = 0
        withAnimation(.easeOut(duration: Self.sweepDuration)) { sweep = 1 }
      }
  }

  @ViewBuilder
  private func fill(for state: SessionState, animated: Bool) -> some View {
    let breath = Palette.breath(for: state, scheme: scheme)
    if let breath, animated, !reduceMotion {
      // No `trigger:` — that overload steps through the phases *once* per
      // change and then stops, which made a card pulse a single time when its
      // state changed and sit still forever after. This one cycles.
      PhaseAnimator([false, true]) { lit in
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
