# Code Session Monitor

Surfaces the coding-agent sessions running on this machine and lets you jump to
the terminal hosting any of them.

## Language

**Session**:
One conversation with a coding agent, identified by the agent's own session
UUID. A session outlives the process running it and keeps its identity even as
its working directory changes.
_Avoid_: Conversation, chat, task

**Tool**:
A coding-agent CLI whose sessions we can observe — Claude Code, Codex, or
OpenCode.
_Avoid_: Agent, CLI, provider, client

**Transcript**:
The on-disk record a tool writes for a session. The primary evidence a session
exists and what it last did.
_Avoid_: Log, history, rollout (Codex's own word for the same thing)

**Working directory**:
Where a session is currently operating. An attribute of a session, never its
identity — a single session moves between directories freely and returns.
_Avoid_: cwd as a synonym for Project; path

**Project**:
The directory a session started in, used as its human-readable label. Stable for
the life of the session even when the working directory moves elsewhere.
_Avoid_: Repo, workspace, folder

**Live process**:
An operating-system process currently running a session. It is the handle by
which we reach a session's terminal, and — by its absence — evidence that a
session has ended. It is never proof of *which* session it belongs to.
_Avoid_: PID as a synonym for the session itself

**Host terminal**:
The terminal application a session's process is running inside, determined from
the environment the session itself exports.
_Avoid_: Shell, console, emulator

## Session state

**Running**:
The agent owns the turn — generating, or executing a tool.

**Waiting**:
The agent has stopped and cannot continue without the user — most importantly,
blocked on a permission prompt. The one state that costs the user time for as
long as it goes unnoticed, and so the one that is never aged out of view.
_Avoid_: Blocked, paused, stuck

**Idle**:
The turn is complete and the session is awaiting the user's next prompt. Not an
error state and not abandonment.
_Avoid_: Done, finished, dead

**Evidence**:
What a session's own store or hook actually said — the last event, when it
happened, how trustworthy the source is, and whether a process is alive. The
only thing stored about a session's condition; everything shown is derived from
it (ADR-0012).
_Avoid_: Status, raw state

**Activity**:
The event evidence records — `turnInFlight`, `blockedOnUser`, `turnComplete`,
`opened`, or `unknown`. Deliberately the common denominator of four very
unequal sources, so `unknown` is a normal value rather than a failure.
_Avoid_: Event type, action

**Liveness**:
Whether a process backs a session: alive, absent, or unknown. `unknown` is a
real observation — a scan that could not run says nothing about a session, and
treating that as absent once emptied the entire display.
_Avoid_: Live as a boolean

**Authoritative state**:
A state the tool itself reported, rather than one we inferred from file
timestamps. Only some tools can report one, so both kinds coexist and inferred
state is the weaker claim.
_Avoid_: Real state, true state, confirmed
