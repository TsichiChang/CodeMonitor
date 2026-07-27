# One adapter per tool, not one uniform scanner

The scanner treated all three tools the same way — tail a JSONL file, scan
processes, infer state from timestamps — because that was the lowest common
denominator. It is a poor fit for all of them, and actively wasteful for
OpenCode, whose sessions were collapsed into a single placeholder card reading
`cwd=unknown` even though OpenCode keeps a full SQLite database with each
session's directory, title, model and token counts.

Each tool now gets an adapter that reads its best available source, behind a
common protocol that yields Sessions.

## Considered options

A uniform scanner plus a single Claude hook was simpler, but it would have left
OpenCode's data unused and forced every future tool through the same
lowest-common-denominator shape.

## Consequences

Three code paths instead of one, and a correspondingly wider test surface. In
exchange, adding a tool means adding an adapter rather than widening a shared
heuristic, and each tool's fidelity is bounded by its own data rather than by
the weakest tool's.

The adapters are less alike than expected. Claude Code and Codex both keep
per-session JSONL and both support appendable hooks, so they differ mainly in
file layout. OpenCode is the opposite: no hook needed, because its SQLite store
already holds each session's directory, title, model and timestamps.

Codex's own structured stores are a trap worth documenting. `state_5.sqlite`
has a `threads` table that looks exactly like the index we want — id, cwd,
title, rollout path — but it stopped being written 40 days before this was
investigated and covered none of the 32 most recent rollouts.
`codex-dev.db`'s `local_thread_catalog` is similarly sparse. The rollout files
remain the only trustworthy Codex source on disk.
