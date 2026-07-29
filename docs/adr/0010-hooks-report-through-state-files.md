# Hooks report through state files, not a socket

A hook is a short-lived shell process that fires whether or not the dashboard is
running. The obvious integration — a socket the app listens on, which is how
Otty does it — drops every event while the app is closed, and loses all
accumulated state whenever it restarts.

Each hook invocation instead writes one small JSON file per session, holding the
reported state, pid, tty, terminal context and a timestamp. The app already
watches the filesystem for changes (ADR-0008), so these files are simply another
watched source rather than a second transport to build and maintain.

## Consequences

State survives the app not running: on launch it reads whatever accumulated,
rather than starting blind until each session next emits an event.

The hook stays trivial — writing a file needs no client library and no path to
our binary, so it cannot break when the app is moved, renamed or uninstalled.
That matters because a broken hook runs inside the user's own agent session.

Files need a cleanup policy, and it has two halves rather than the three this
originally claimed. The hook deletes its own file on the tool's end event, where
the tool has one — Claude Code's `SessionEnd`; Codex fires nothing of the kind,
so its files are only ever swept. The sweep is the second half: anything still
present after seven days is dropped at launch, which covers the session that was
killed and never got to run its own end event.

Ageing out of the *display* deletes nothing, and does not need to. Reported state
carries a timestamp, so an old file is recognisable as stale rather than trusted
indefinitely — and a session rebuilt from one fails the liveness window on the
same scan that reads it, so it never reaches the screen. Deleting on age-out
would also be the wrong instinct: the display's window is minutes, while a
session quiet for an afternoon with its agent still alive is exactly the case
these files exist to survive.
