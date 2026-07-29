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
"$APP" --diagnose                 # sessions + the host resolved for each
"$APP" --focus oversea-fop        # actually jump to the matching session
"$APP" --focus-next --dry-run     # the order the global shortcut works through
"$APP" --dismiss spare            # hide an idle session until it acts again
"$APP" --restore                  # un-hide everything
"$APP" --selftest                 # evidence derivation + layout ratios
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
| `Services/GlobalHotKey.swift` | The system-wide jump shortcut, through Carbon |
| `Services/Shell.swift` | Bounded child-process execution (jump path only) |
| `Views/Metrics.swift` | Every length, derived from the screen's point density |
| `Views/AmbientBand.swift` | The edge glow — AppKit, above full-screen apps |
| `Views/SessionCardView.swift` | One tile, in both shapes — an idle session is the same tile folded shut |
| `Views/` | SwiftUI dashboard, cards, menu bar, settings |

## Being noticed, and getting there

Measured over two weeks of transcripts, an agent sat waiting more than five
minutes **7.6 times a day while the user was at the keyboard, in another
session** — three times a day beyond ten minutes. The menu-bar icon was already
amber through every one of them. It went unseen because it is small, still, and
outside where the eye is pointed (ADR-0014).

So two things exist for that, and neither of them is the dashboard:

- **A glow at the bottom edge of every screen** while a session is blocked on
  you. It breathes — brighter and faster the longer the wait — and says nothing
  about *which* session, because identity costs a glance and avoiding the glance
  is the point. It sits above full-screen apps, passes clicks through, takes no
  focus and needs no permission. Turn it off in Settings.
- **⌃⌥⌘J jumps to whatever most deserves attention** — longest-waiting first,
  then running, then idle. Press again within eight seconds and it advances to
  the next; after that it starts from the most urgent again. There is no
  selection to aim with, and so nothing on screen has to show one: arriving is
  what answers "which session?". `--focus-next --dry-run` prints the order.

Every wait that lights the band was reported by the tool itself, because that is
the only kind there is: `waiting` is derived from one event, which one source
emits (ADR-0020). Silence is never read as a permission prompt — a turn that has
gone quiet reads as `running 12m`, which states a fact instead of guessing at a
reason.

Re-run `tools/dead-wait.py` after a week: if 7.6 drops to one or two, the glow
did its job.

## How a session is classified

A session stores only *evidence* — what its source last saw, when, how
trustworthy that source is, and whether a process is alive. State, lifetime and
appearance are each derived from it in one place and never from each other
(ADR-0012). `Models/Evidence.swift` holds both the model and the derivation;
`--selftest` runs the table.

That structure is not decoration. Seven defects had landed in the previous
arrangement, where one enum decided the label, the lifetime, the colour and the
poll rate at once, so a single wrong `running` was four bugs. Every one of them
is now a line in the check table.

`--diagnose` prints each session's evidence alongside its derived state, and
marks the source `reported` or `inferred` — the difference between "the tool
said so" and "this was read off a file's timestamp". Both appear on screen; what
inference may no longer produce is `waiting` (ADR-0020).

## Reporting state from hooks

Hooks are what let each tool say what it is doing instead of it being guessed at,
and they are why `waiting` can be trusted at all: it is derived from one event,
which one source emits. Without them nothing breaks — state stays inferred, and
a session sitting on a permission prompt reads as `running` until it ages out.

**Settings → "Report state from hooks"** installs and removes them per tool. The
same thing from the CLI:

```bash
"$APP" --hooks              # what is installed, per tool
"$APP" --install-hooks
"$APP" --uninstall-hooks
```

This writes to files the app does not own — `~/.claude/settings.json` and
`~/.codex/hooks.json` — which also hold other integrations' hooks. So it copies
each to a dated backup first, **appends** to each event's array rather than
replacing it, tags its own entries with `_codemonitor`, and takes only those out
again on uninstall. Installing twice updates in place instead of duplicating.
Sessions already running keep their old setup until they restart.

### What it writes

Worth knowing if you want to check the result, or register it by hand:

```jsonc
// under "hooks", one of these objects is appended to each named event's array:
{ "_codemonitor": true,
  "hooks": [{ "type": "command",
    "command": "~/.claude/hooks/codemonitor-hook.sh - \"$PPID\"" }] }
```

Which event fired is read from the payload Claude sends on stdin, so the command
is the same on every event but two:

| Event | Command | Why |
|---|---|---|
| `SessionStart` | `... - "$PPID" locate` | |
| `UserPromptSubmit` | `... - "$PPID" locate` | |
| `SessionEnd` | `... ended "$PPID"` | removes the session's state file — nothing later will |
| `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`, `Stop`, `StopFailure` | `... - "$PPID"` | |

The first argument once named the state each event meant, which made a line in
`settings.json` the authoritative definition of a state. What an event means is
now decided in Swift (ADR-0012) and anything but `ended` there is ignored, so an
older registration keeps working untouched — `-` is only a placeholder holding
the position of the pid.

The trailing `locate` argument tells the hook to also record which terminal pane
the session is in — the pane rather than the tab, because a split tab can hold
several sessions and this is what tells them apart.

It is passed only on those two events because they are the moments the session's
pane is certainly focused — the user has just typed into it — and Otty can only
be asked what is focused, never what is calling (ADR-0009).

The script itself is installed to `~/.claude/hooks/codemonitor-hook.sh`, inside
your own directory rather than referenced inside the app bundle, so moving or
replacing the app cannot silently break every registered hook.

State is written to `~/.local/state/codemonitor/sessions/<session-id>.json`, one
file per session, which is why it survives the app being closed. Set
`CODEMONITOR_STATE_DIR` to relocate it. `--uninstall-hooks` takes the entries
back out; the state directory is left for you to delete.

### Codex

The same script, told which tool it is speaking for, registered in
`~/.codex/hooks.json` — each event is a list there too, so it coexists with
whatever else is registered:

```jsonc
{ "hooks": [{ "type": "command",
  "command": "CODEMONITOR_TOOL=codex ~/.claude/hooks/codemonitor-hook.sh - \"$PPID\"" }] }
```

Codex fires four events — `SessionStart`, `UserPromptSubmit`, `Stop`,
`PermissionRequest` — and the names mean what they mean for Claude, so the same
interpretation applies with nothing added. What is missing is `PreToolUse` and
`PostToolUse`: a Codex turn reports its start and its end but nothing in
between, so a long turn stays `running` on the strength of the last
`UserPromptSubmit` rather than being re-confirmed by each tool call.

Codex also has a `notify` command, and it is **not** usable for this. Unlike the
hook arrays it is a single command per installation — `config.toml` holds one —
so registering there would evict whatever is already using it rather than join
it.

Check it end to end without waiting for a real session:

```bash
printf '%s' '{"payload":{"id":"test-1","cwd":"'"$PWD"'"},"hook_event_name":"PermissionRequest"}' \
  | CODEMONITOR_TOOL=codex ~/.claude/hooks/codemonitor-hook.sh - $$
cat ~/.local/state/codemonitor/sessions/test-1.json
```

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
