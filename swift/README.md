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
"$APP" --diagnose              # sessions + the host resolved for each
"$APP" --focus oversea-fop     # actually jump to the matching session
"$APP" --dismiss spare         # hide an idle session until it acts again
"$APP" --restore               # un-hide everything
```

## App icon

`Resources/AppIcon.icns` is generated, not hand-drawn — `Tools/make-icon.swift`
draws it with CoreGraphics using the same state colours as the dashboard, so the
two cannot drift apart. To change it, edit the drawing and re-run:

```bash
swiftc -O Tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon /tmp/icon.png
mkdir -p /tmp/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s /tmp/icon.png --out "/tmp/AppIcon.iconset/icon_${s}x${s}.png"
  sips -z $((s*2)) $((s*2)) /tmp/icon.png --out "/tmp/AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
```

The generator is committed because the previous icon was not: it lived only as
an ignored binary in the working tree, so when it was deleted there was nothing
to restore it from.

## Layout

| Path | Role |
|---|---|
| `Models/Session.swift` | Session/state types shared by scanner and views |
| `Services/Adapters/` | One source per tool, each reading its own store |
| `Services/TranscriptReader.swift` | JSONL tail/head reading + parsing |
| `Services/OpenCodeStore.swift` | Read-only SQLite reader for OpenCode's session index |
| `Services/HookStateStore.swift` | State files agent hooks leave behind |
| `Services/ProcessScanner.swift` | Live-process discovery through libproc, no subprocesses |
| `Services/SessionScanner.swift` | Merges sources, processes and reports into a snapshot |
| `Services/TerminalFocus.swift` | Jump-to-terminal, per-host |
| `Services/SessionMonitor.swift` | `@Observable` poll loop driving the UI |
| `Services/Shell.swift` | Bounded child-process execution (jump path only) |
| `Views/` | SwiftUI dashboard, cards, menu bar, settings |

## How a session is classified

Transcripts on disk are the source of truth; live processes only confirm a
session is still open. A trailing `tool_use` with no result is `running` while
fresh, `waiting` once it has sat unanswered past the approval threshold, and
`idle` when clearly abandoned. Thresholds live in `Adapters/SessionSource.swift`.

That is all inference. A session can also *report* its state, which is both more
accurate and the only way to distinguish "blocked on a permission prompt" from
"has been quiet for 45 seconds" — `--diagnose` marks each state `reported` or
`inferred`.

## Reporting state from hooks (optional)

Installing the hook is opt-in and changes a file this app does not otherwise
touch, so it is a manual step. Nothing breaks without it; state stays inferred.

Copy the script somewhere stable and make it executable:

```bash
mkdir -p ~/.claude/hooks
cp swift/hooks/codemonitor-hook.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/codemonitor-hook.sh
```

Then **append** an entry to each event's array in `~/.claude/settings.json` —
that file already holds other integrations' hooks, and every event is a list
precisely so several can coexist. Do not replace what is there.

```jsonc
// under "hooks", add one of these objects to each named event's array:
{ "hooks": [{ "type": "command",
  "command": "~/.claude/hooks/codemonitor-hook.sh <state> \"$PPID\"" }] }
```

| Event | `<state>` | Notes |
|---|---|---|
| `SessionStart` | `idle` | append ` locate` — a new session is awaiting its first prompt |
| `UserPromptSubmit` | `running` | append ` locate` |
| `PreToolUse` | `running` | |
| `PostToolUse` | `running` | |
| `PermissionRequest` | `waiting` | the signal none of the inference can match |
| `Notification` | `waiting` | |
| `Stop` | `idle` | |
| `SessionEnd` | `ended` | removes the session's state file |

The trailing `locate` argument tells the hook to also record which terminal pane
the session is in — the pane rather than the tab, because a split tab can hold
several sessions and this is what tells them apart.

It is passed only on those two events because they are the moments the session's
pane is certainly focused — the user has just typed into it — and Otty can only
be asked what is focused, never what is calling (ADR-0009).

State is written to `~/.local/state/codemonitor/sessions/<session-id>.json`, one
file per session, which is why it survives the app being closed. Set
`CODEMONITOR_STATE_DIR` to relocate it. To undo everything, remove the entries
from `settings.json` and delete that directory.

## Sub-agents

A program that farms work out to sub-agents gets one transcript per agent, and
each looks exactly like a session — 26 appeared under one project here against 9
sessions actually opened by hand. They are folded into a count on the session
that spawned them (`⬡ 3` on the card) rather than listed, because burying the
sessions a person is sitting in front of is the one thing this display must not
do. "List sub-agents separately" in Settings turns the folding off.

They are told apart by `entrypoint`, which every transcript record carries:
`cli` and `claude-desktop` are people, `sdk-cli` and `sdk-ts` are programs.
`isSidechain` looks like the right field and is never set. Attribution is by
project directory — nothing in a transcript names the session that spawned it.

## How the terminal jump works

The host terminal is identified from the session's own `TERM_PROGRAM`
environment variable, **not** by walking the process tree —
Otty re-parents its shells away from the GUI process, so a ppid walk never
reaches it.

Once the host is known it is addressed directly, so no unrelated terminal gets
probed (which would trigger its Automation prompt for nothing):

- **Otty** — `otty-cli`, needing no Automation permission. With a hook
  installed the session's own pane was recorded and is focused directly;
  otherwise the match is by working directory, which cannot separate two tabs in
  the same directory. Otty's AppleScript dictionary declares a `tty` property
  but always returns an empty string, so tty-based matching cannot work there
  either way. A recorded location is used only if it still exists and still sits
  in the session's directory.
- **Terminal.app / iTerm2** — AppleScript, selecting the tab whose tty matches.
  Prompts for Automation permission the first time.
- **Anything else** — the app is brought to the front, without tab selection.

Not every session lives in a terminal: editors and desktop apps launch agents
too, and those have no tty and no `TERM_PROGRAM`. The app that launched the
process names itself in the process's environment (`__CFBundleIdentifier`), so
those sessions activate their own host — Obsidian, Claude Desktop, whatever it
is — rather than being unreachable.

## Requirements

- macOS 14+, Swift 6
- **Not sandboxed** — process discovery reads other processes through libproc,
  and jumping shells out to `osascript` / `otty-cli`. An App Sandbox entitlement
  breaks both.
- Signed with a stable identity. macOS ties Automation permission to the code
  signature, so an ad-hoc signature (which changes every rebuild) makes the
  permission prompt reappear each time. `build-app.sh` prefers an
  "Apple Development" identity matching the repo's git email; override with
  `SIGN_ID=...`.
