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

  static let green20Light = Color(hex: 0xDDF3E4)
  static let green40Light = Color(hex: 0xCCEBD7)
  static let green20Dark = Color(hex: 0x174933)
  static let green40Dark = Color(hex: 0x20573E)

  static let orange20Light = Color(hex: 0xFFDFB5)
  static let orange40Light = Color(hex: 0xFFD19A)
  static let orange60Light = Color(hex: 0xFFC182)
  static let orange20Dark = Color(hex: 0x462100)
  static let orange40Dark = Color(hex: 0x562800)
  static let orange60Dark = Color(hex: 0x66350C)

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
      return (resting(scheme), dark ? green40Dark : green20Light, 2.4)
    case .waiting:
      // Always amber, pulsing between two steps — faster, so it reads as urgent.
      return dark
        ? (orange40Dark, orange60Dark, 1.2)
        : (orange20Light, orange40Light, 1.2)
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
