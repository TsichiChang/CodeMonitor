/// A single session tile.
///
/// One view for both shapes, not two. An idle session is this same tile with
/// its detail collapsed and its height reduced — because the alternative, a
/// separate row view swapped in by state, can only ever cross-fade: two
/// different views in two different containers, tied together by a geometry
/// match, read as a hand-off rather than as one thing folding shut. Height is
/// therefore explicit and driven by state, which is the one property SwiftUI
/// can interpolate cleanly.
///
/// Flat and airy: a hairline border, with the background tint following live
/// state (green while running, amber while waiting) and pulsing ("breathing")
/// between two tint steps so the state reads at a glance. Waiting breathes
/// faster than running for urgency. Clicking jumps to the session's terminal.

import SwiftUI

struct SessionCardView: View {
  let session: SessionInfo
  let onFocus: () -> Void
  /// Present only for sessions the user is allowed to close — idle ones.
  var onDismiss: (() -> Void)?

  @Environment(\.colorScheme) private var scheme
  @Environment(\.metrics) private var metrics
  @State private var isHovering = false

  private var isIdle: Bool { session.state == .idle }

  /// Height of the detail block when open, stated rather than measured so that
  /// closing it is an interpolation between two numbers. A natural height
  /// cannot be animated to zero — and hiding it with opacity alone left the
  /// space behind, which pushed the header out of a tile clipped to one row.
  private var detailHeight: Double {
    metrics.caption * 1.4 + metrics.cardSpacing + metrics.caption * 1.6
  }

  /// Padding that keeps the header centred in a folded tile, so `idleRowHeight`
  /// still describes what a collapsed tile measures.
  private var verticalPadding: Double {
    isIdle
      ? max(metrics.cardSpacing * 0.5, (metrics.idleRowHeight - metrics.body * 1.35) / 2)
      : metrics.cardPadding
  }

  var body: some View {
    Button(action: onFocus) {
      VStack(alignment: .leading, spacing: isIdle ? 0 : metrics.cardSpacing) {
        header
        detail
          // Both the height and the opacity close. The height is what makes it
          // fold; the opacity keeps text from looking crushed on the way down.
          .frame(height: isIdle ? 0 : detailHeight, alignment: .top)
          .opacity(isIdle ? 0 : 1)
          .clipped()
      }
      .padding(.horizontal, metrics.cardPadding)
      .padding(.vertical, verticalPadding)
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
    .overlay(alignment: .topTrailing) { dismissButton }
    .onHover { isHovering = $0 }
    .help("Jump to terminal")
  }

  /// Shown on hover only. A tile that is always wearing a close button invites
  /// being tidied away; this one has to be reached for.
  @ViewBuilder
  private var dismissButton: some View {
    if let onDismiss, isHovering {
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: metrics.caption * 0.8, weight: .bold))
          .foregroundStyle(.secondary)
          .padding(metrics.caption * 0.4)
          .background(Circle().fill(.background.opacity(0.75)))
      }
      .buttonStyle(.plain)
      .padding(.top, isIdle ? metrics.caption * 0.5 : metrics.cardPadding * 0.79)
      .padding(.trailing, metrics.cardPadding * 0.5)
      .help("Hide until this session does something new")
      .transition(.opacity)
    }
  }

  /// Present in both shapes, so nothing about it moves when the tile folds.
  private var header: some View {
    HStack(alignment: .center, spacing: metrics.cardSpacing * 0.7) {
      Circle()
        .fill(Palette.statusColor(session.state))
        .frame(width: metrics.caption * 0.55, height: metrics.caption * 0.55)

      Text(session.project)
        .font(.system(size: isIdle ? metrics.body * 0.88 : metrics.body,
                      weight: isIdle ? .regular : .semibold))
        .foregroundStyle(isIdle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .lineLimit(1)
        .truncationMode(.middle)

      if isIdle, session.subagentCount > 0 {
        Label("\(session.subagentCount)", systemImage: "circle.hexagongrid")
          .font(.system(size: metrics.caption * 0.9))
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: metrics.cardSpacing * 0.5)

      Text(Self.relativeTime(session.lastActivity))
        .font(.system(size: metrics.caption))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        // The close button is an overlay in this corner; its width is reserved
        // whether or not it shows, so the time never jumps sideways on hover.
        .padding(.trailing, onDismiss == nil ? 0 : metrics.body * 0.9)
    }
  }

  /// Everything an idle session does not get. Dropped because of state, not
  /// because of size — these stay on an active tile even on a small screen,
  /// and come back the moment the session acts again (ADR-0013).
  private var detail: some View {
    VStack(alignment: .leading, spacing: metrics.cardSpacing) {
      metaRow
      statusRow
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
    // Reserved even when empty so tiles keep a uniform height.
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

/// Pulses the tile background between two tints of the same hue.
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
