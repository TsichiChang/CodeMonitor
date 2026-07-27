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

Files need a cleanup policy; a session's file is removed when its session ends
or ages out. Reported state carries a timestamp so a file left behind by a
crashed session can be recognised as stale rather than trusted indefinitely.
