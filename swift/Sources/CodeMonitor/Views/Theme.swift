/// Color tokens for session state.
///
/// Running and waiting cards "breathe" between two tints of the same hue so the
/// state reads at a glance without hovering. Waiting breathes twice as fast as
/// running to convey urgency. Values are kept here as named constants so the
/// exact greens/oranges stay easy to tune.

import SwiftUI

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}

enum Palette {
  // Resting card background (also the "not green" end of the green breath).
  static let controlSubtleLight = Color(hex: 0xF2F2F5)
  static let controlSubtleDark = Color(hex: 0x232326)

  // Breath endpoints. The swing is wider than it looks like it needs to be:
  // these are read as a slow modulation over seconds, not as two swatches side
  // by side, and the eye is far worse at the former. A pair separated by
  // ΔE ≈ 12 — an unmistakable difference when adjacent — is close to invisible
  // spread across a 1.2s fade, so each pair here sits around ΔE 20–28.
  static let greenRestLight = Color(hex: 0xC3E8D1)
  static let greenRestDark = Color(hex: 0x2C7A55)

  static let orangeLowLight = Color(hex: 0xFFDFB5)
  static let orangeHighLight = Color(hex: 0xFFBE6E)
  static let orangeLowDark = Color(hex: 0x562800)
  static let orangeHighDark = Color(hex: 0x8A4A10)

  /// Menu-bar tint for the most urgent state present.
  static let statusRunning = Color(hex: 0x34C759)
  static let statusWaiting = Color(hex: 0xF5A623)

  static func resting(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? controlSubtleDark : controlSubtleLight
  }

  /// The two ends of a state's breath, and how long one full cycle takes.
  static func breath(
    for state: SessionState, scheme: ColorScheme
  ) -> (from: Color, to: Color, period: Double)? {
    let dark = scheme == .dark
    switch state {
    case .running:
      // Pulses between the resting tint and green — "green ↔ not green".
      return (resting(scheme), dark ? greenRestDark : greenRestLight, 2.4)
    case .waiting:
      // Always amber, pulsing between two steps — faster, so it reads as urgent.
      return dark
        ? (orangeLowDark, orangeHighDark, 1.2)
        : (orangeLowLight, orangeHighLight, 1.2)
    case .idle:
      return nil
    }
  }

  static func statusColor(_ state: SessionState) -> Color {
    switch state {
    case .running: statusRunning
    case .waiting: statusWaiting
    case .idle: .secondary
    }
  }
}
