# A session need not have a process

Codex sessions started from the desktop app were detected correctly — identity,
project, inferred state, all right — and then vanished from the display about
five minutes later while still running. They also could not be jumped to.

Both follow from an assumption this app was built on and had never had to state:
*a session is backed by a process that can be found and matched by directory.*
Every source honoured it, and for terminal sessions it holds. For a desktop host
it fails twice over. What the machine actually shows:

```
originator: Codex Desktop
cwd:        ~/.codex/worktrees/40de/globalpay_cashier   ← a worktree Codex made
processes:  /Applications/ChatGPT.app/…/codex-code-mode-host      cwd /
            /Applications/ChatGPT.app/…/Codex Framework.framework cwd /
```

The processes belong to the *app*, not to any session: they sit at `/`, which
the scanner already excludes as meaningless (ADR-0006), and there are several of
them regardless of how many sessions exist. Meanwhile the session's directory is
a worktree the app created, which is nobody's working directory. Nothing can be
matched to anything.

`liveness = .absent` was therefore being claimed on the strength of a lookup
that could not have succeeded — and `absent` is the strongest statement in that
enum, worth only five minutes of grace (ADR-0005).

## The decision

A session may carry `hostBundleID`, set when its own record says a desktop app
launched it — for Codex that is `originator`. Two things follow, and both are
corrections rather than features:

**Liveness stays `unknown`.** ADR-0012 put `unknown` in the vocabulary for
exactly this: an observation that could not be made. A scan that finds no
process for a session that never had one has learned nothing, and saying
`absent` is a claim it did not earn. This buys the thirty-minute window instead
of five, which covers a long turn — a Codex reasoning pass can go twenty minutes
without writing to its rollout.

**Jumping means activating the app.** It is tried first and alone: there is no
pid worth resolving and no tty to probe, so every other branch would fail on its
way to the same answer.

## Consequences

The jump is coarse. A terminal session lands on its pane; a desktop session
brings the window forward and stops there, because the app exposes no tab or
pane to address. If it holds several sessions, the user arrives near the right
one rather than at it.

An idle desktop session still ages out at thirty minutes, and unlike a terminal
session there is nothing that could keep it. `alive` is what makes a quiet
terminal session stay indefinitely, and nothing here can honestly say `alive`.

One signal was left on the table: whether the host app is running at all.
`NSWorkspace` would answer it cheaply, and a *stopped* app is proof its sessions
are over — which would let those expire at once instead of lingering thirty
minutes. It is not that they linger wrongly; it is that this would be sharper.
It was not done because it moves an AppKit call into the scanner, and the
current behaviour is already correct, only conservative.
