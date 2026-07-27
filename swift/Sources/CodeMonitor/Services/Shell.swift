/// Bounded child-process execution.
///
/// Every call has an explicit timeout so a hung `ps`/`lsof`/`osascript` can
/// never stall a poll cycle. stdout is drained on the calling queue while the
/// child runs, so a large result never deadlocks on a full pipe buffer.

import Foundation

enum Shell {
  struct Output: Sendable {
    let stdout: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
    var trimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  /// Runs `executable` with `arguments`. Returns nil when the process could not
  /// be spawned at all (missing binary, denied exec).
  static func run(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval = 10
  ) async -> Output? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
      DispatchQueue.global(qos: .utility).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
          try process.run()
        } catch {
          continuation.resume(returning: nil)
          return
        }

        // Watchdog only terminates; the main path below still completes normally
        // (terminate closes the pipe, so readToEnd returns), which keeps the
        // continuation resumed exactly once.
        let watchdog = DispatchWorkItem {
          if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()

        continuation.resume(
          returning: Output(
            stdout: String(decoding: data, as: UTF8.self),
            exitCode: process.terminationStatus
          )
        )
      }
    }
  }
}
