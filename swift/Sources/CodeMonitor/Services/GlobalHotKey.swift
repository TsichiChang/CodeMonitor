/// A system-wide shortcut, registered through Carbon.
///
/// `RegisterEventHotKey` is the one way to do this that needs no entitlement
/// and shows no permission prompt. `NSEvent.addGlobalMonitorForEvents` would
/// require Accessibility access, and a `.keyboardShortcut` in a SwiftUI menu
/// only fires while that menu is open — neither is usable for a key pressed
/// while another app is frontmost, which is every press this exists for
/// (ADR-0014).

import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotKey {
  /// ⌃⌥⌘J. Three modifiers because this takes the key away from every other
  /// app on the machine, and a two-modifier combination is something a real
  /// editor is likely to want.
  nonisolated static let defaultKey = (code: UInt32(kVK_ANSI_J),
                           modifiers: UInt32(controlKey | optionKey | cmdKey))

  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: () -> Void

  /// The registered instance. The Carbon callback is a plain C function with
  /// nowhere to carry context, so it finds its way back here.
  private static var active: GlobalHotKey?

  /// Returns nil when the combination is already taken by something else.
  /// Where a failed registration reports itself.
  ///
  /// A menu-bar app has no console — `print` goes nowhere and `NSLog` did not
  /// reach the unified log from here — and a hot key that fails to register
  /// does so silently, which is exactly how this went unnoticed once already.
  /// Only failures are written; a working shortcut says nothing.
  nonisolated static let logPath = "/tmp/codemonitor-hotkey.log"

  nonisolated static func note(_ message: String) {
    let line = "\(Date()) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
  }

  init?(code: UInt32 = defaultKey.code,
        modifiers: UInt32 = defaultKey.modifiers,
        action: @escaping () -> Void) {
    self.action = action

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let installed = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, _ in
        // Hot-key events are dispatched on the main run loop.
        MainActor.assumeIsolated { GlobalHotKey.active?.action() }
        return noErr
      },
      1, &eventType, nil, &handler)
    guard installed == noErr else {
      Self.note("InstallEventHandler failed: \(installed)")
      return nil
    }

    let id = EventHotKeyID(signature: OSType(0x434D_4E54), id: 1)  // 'CMNT'
    let registered = RegisterEventHotKey(
      code, modifiers, id, GetApplicationEventTarget(), 0, &reference)
    guard registered == noErr, reference != nil else {
      // -9878 is eventHotKeyExistsErr: another process owns this combination.
      Self.note("RegisterEventHotKey failed: \(registered)")
      if let handler { RemoveEventHandler(handler) }
      return nil
    }

    Self.active = self
  }

  /// Gives the key back to the rest of the system.
  ///
  /// Not a `deinit`: Carbon's refs are not `Sendable`, and Swift 6 will not let
  /// a nonisolated deinit touch them. In practice this object lives as long as
  /// the app does and the registration dies with the process — so this exists
  /// for turning the shortcut off, not for cleanup.
  func unregister() {
    if let reference { UnregisterEventHotKey(reference) }
    if let handler { RemoveEventHandler(handler) }
    reference = nil
    handler = nil
    if Self.active === self { Self.active = nil }
  }

  /// How the shortcut reads in a menu or settings pane.
  nonisolated static var displayName: String { "⌃⌥⌘J" }
}
