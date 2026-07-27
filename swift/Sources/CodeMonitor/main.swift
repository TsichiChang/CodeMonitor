/// Entry point.
///
/// Dispatches to the CLI diagnostics when invoked with a recognized flag,
/// otherwise launches the normal menu-bar app.
///
/// This file must stay free of top-level `await`. Top-level code containing
/// `await` turns the whole file into an async context, which changes how the
/// main actor's executor is installed — SwiftUI still draws, but `Task`s
/// created by the app (including the session poll loop) never get scheduled.

import Foundation

if Diagnostics.handles(CommandLine.arguments) {
  Diagnostics.runBlocking(arguments: CommandLine.arguments)
  exit(0)
}

CodeMonitorApp.main()
