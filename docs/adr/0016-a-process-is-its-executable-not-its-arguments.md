# A process is its executable, not its arguments

A card titled `swift` kept appearing for about a second and vanishing. There is
no such project — `swift` is a subdirectory of this repository — and no session
had ever run there.

It reproduces in one line:

```bash
cd swift && zsh -c 'sleep 9; ls /tmp/claude '
```

That shell becomes a session:

```
• swift  [claude]  running (inferred)
    id:    claude:pid-24442
    project: /Users/ziqizhang/Repos/CodeMonitor/swift
```

Nothing about it is an agent. It matched because `ProcessScanner` tests its
patterns against the **whole command line**, arguments included, and one of them
happened to contain `/claude `. Claude Code's own Bash tool spawns exactly such a
shell for every command it runs, in whatever directory the session is currently
working in — so any command mentioning the agent's name mints a card that lives
as long as the command does.

**The decision: a tool is recognised from `argv[0]`, and from `argv[1]` when
`argv[0]` is an interpreter.** The second position is needed because these CLIs
also ship as wrapped scripts (`node …/claude-code/cli.js`), which is why the
patterns were written against the full line to begin with. Everything past that
is data the process was asked to operate on, and data must not decide what a
process *is*.

## The directory key made it visible

A second defect let the phantom through even though the real session was already
listed. Sessions with no matching process are emitted by directory:

```swift
let covered = Set(sessions.map { "\($0.tool.rawValue):\($0.projectPath)" })
```

The real session's `projectPath` is the repository root; the stray shell's cwd
was `…/CodeMonitor/swift`. Different strings, so it was not covered, so it
became its own card — and titled itself from that directory.

This is exactly what ADR-0002 forbids: *"A session is identified by its UUID,
not its working directory."* That rule was applied to the transcript sources and
not to this path, where a directory is still doing the work of an identity. It
cannot be fixed by keying on the UUID, because a bare process has no UUID to
key on — which is the honest reason this fallback exists at all, and the reason
it must be conservative about what it claims to have found.

## The same restraint applies to where it is running

A second phantom appeared later, titled with the user's own name and gone within
a minute. It came from the same fallback, correctly identifying a real agent
this time: a desktop app launches its process before a project is chosen, so the
working directory sits at the home folder until the user picks one.

That is a real agent, but there is nothing to show for it. The card is titled
from the directory, so it reads as the user's account name — which names no
project, and costs a row on a display where rows are contested (ADR-0006). The
home directory is therefore excluded here, alongside `/`.

The exclusion is narrow on purpose: it applies only to processes with no session
behind them. A session that genuinely runs in the home directory has a
transcript, arrives through its own source, and is unaffected. What is being
refused is not the directory — it is claiming a session exists on the strength
of a process that has not yet been given anything to do.

## Consequences

Fewer phantom cards, and a real risk of the opposite: an agent launched in a way
that puts its name only in a later argument will no longer be recognised. That
is the safer failure. A session missing from the display is a session the user
knows about from their own terminal; a session that never existed is a card that
asks for attention on behalf of nothing, on a display whose entire premise is
that everything shown deserves a look (ADR-0007).
