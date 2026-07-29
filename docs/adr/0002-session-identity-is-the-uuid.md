# A session is identified by its UUID, not its working directory

Sessions were identified by working directory (`tool:cwd:sessionId`, joined to
live processes through a dictionary keyed on cwd). The working directory is not
stable within a session: one observed session moved between two directories nine
times, and each move renamed the card, changed the session's id, broke the match
to its own process, and caused a second phantom card to be created for the
process that no longer matched anything.

Identity is now the session UUID the tool itself assigns. The working directory
becomes an ordinary attribute, and the **first** recorded one is the session's
Project — stable, and what everything external is keyed on.

Everything that matches a session to something outside itself uses the Project,
not the latest directory. An agent process keeps the directory it was launched
in and does not follow the session around: for a session whose transcript had
moved to `…/CodeMonitor/swift`, both of its processes still reported
`…/CodeMonitor`. A terminal tab behaves the same way, for the same reason — its
shell is the agent's parent, not its follower (ADR-0009).

The latest recorded directory is therefore informational only: it says where the
session is working, and is worth showing, but nothing is matched on it.

## Consequences

Process scanning cannot recover a session's UUID. Processes do not hold their
transcript open, and the UUID in `--resume` argv is the *parent* session for a
forked session — actively misleading. So a live process can only ever be matched
to a session heuristically.

> **The clause that followed this was wrong and has been removed.** It read "…
> which is why the snapshot no longer carries a pid (see ADR-0003)", and both
> halves have since inverted: ADR-0003 reversed itself — process state is read
> on every scan — and a session does carry a pid. The reversal does not touch
> the rule above. A pid is a decoration and a lifetime signal; the heuristic is
> confined to *attaching* one, and never decides what a session is.
