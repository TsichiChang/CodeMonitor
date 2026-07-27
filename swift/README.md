# Code Monitor (Swift)

Native macOS rewrite of the Code Session Monitor — a menu-bar app that surfaces
local coding-agent sessions (Claude Code, Codex, OpenCode) and jumps to the
terminal tab running each one.

Replaces the previous Glaze/React implementation in `main/` + `renderer/`.
The detection logic is a direct port; the UI is SwiftUI.

## Build

```bash
./build-app.sh            # release build → build/Code Monitor.app
CONFIG=debug ./build-app.sh
open "build/Code Monitor.app"
```

`swift build` alone compiles the binary but does not produce a launchable
bundle — the app needs its `Info.plist` (menu-bar role, Apple Events usage
description), which `build-app.sh` assembles.

## Diagnostics

The binary doubles as a CLI over the same code paths the GUI uses — handy when a
session isn't detected or a jump lands in the wrong tab:

```bash
APP="build/Code Monitor.app/Contents/MacOS/CodeMonitor"
"$APP" --diagnose              # sessions + the terminal host resolved for each
"$APP" --focus oversea-fop     # actually jump to the matching session
```

## Layout

| Path | Role |
|---|---|
| `Models/Session.swift` | Session/state types shared by scanner and views |
| `Services/Shell.swift` | Bounded child-process execution (every call has a timeout) |
| `Services/TranscriptReader.swift` | JSONL tail/head reading + parsing |
| `Services/ProcessScanner.swift` | `ps`/`lsof` discovery of live agent processes |
| `Services/SessionScanner.swift` | Collectors + state classification, caches (an `actor`) |
| `Services/TerminalFocus.swift` | Jump-to-terminal, per-host |
| `Services/SessionMonitor.swift` | `@Observable` poll loop driving the UI |
| `Views/` | SwiftUI dashboard, cards, menu bar, settings |

## How a session is classified

Transcripts on disk are the source of truth; live processes only confirm a
session is still open. A trailing `tool_use` with no result is `running` while
fresh, `waiting` once it has sat unanswered past the approval threshold, and
`idle` when clearly abandoned. Thresholds live at the top of
`SessionScanner.swift`.

## How the terminal jump works

The host terminal is identified from the session's own `TERM_PROGRAM`
environment variable (read via `ps -E`), **not** by walking the process tree —
Otty re-parents its shells away from the GUI process, so a ppid walk never
reaches it.

Once the host is known it is addressed directly, so no unrelated terminal gets
probed (which would trigger its Automation prompt for nothing):

- **Otty** — `otty-cli tab focus`, matched by working directory.
  Otty's AppleScript dictionary declares a `tty` property but always returns an
  empty string, so tty-based tab matching cannot work there. The CLI path also
  needs no Automation permission.
  *Known limit:* several tabs in the same directory are indistinguishable over
  the CLI; a titled tab wins (Otty badges tabs running an agent), else the
  lowest index.
- **Terminal.app / iTerm2** — AppleScript, selecting the tab whose tty matches.
  Prompts for Automation permission the first time.
- **Anything else** — the app is brought to the front, without tab selection.

## Requirements

- macOS 14+, Swift 6
- **Not sandboxed** — the app shells out to `ps`, `lsof`, `osascript`, and
  `otty-cli`. Adding an App Sandbox entitlement breaks session detection
  entirely.
- Signed with a stable identity. macOS ties Automation permission to the code
  signature, so an ad-hoc signature (which changes every rebuild) makes the
  permission prompt reappear each time. `build-app.sh` prefers an
  "Apple Development" identity matching the repo's git email; override with
  `SIGN_ID=...`.
