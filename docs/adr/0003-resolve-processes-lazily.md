---
status: superseded — process state is read on every scan, see below
---

# Live processes are read on every scan, through libproc

This decision originally went the other way: process lookup was to happen only
when the user jumped to a terminal. Both of its premises turned out to be wrong.

**"It costs a `ps` plus an `lsof` per agent, every two seconds."** True of
subprocesses, not of the information. `proc_listpids`, `KERN_PROCARGS2` and
`proc_pidinfo` return the same command lines, working directories and terminals
without spawning anything: about 4ms of a 36ms scan. The whole scan used to cost
69ms, most of it waiting on children.

**"…purely to decorate cards with a pid nobody reads."** The pid turned out to
carry the two things the list most depends on. It decides whether a session is
still open — a store can be quiet for hours while its agent sits there alive,
and without that signal such a session drops off the display it exists to be
seen on. And `KERN_PROCARGS2` exposes the `--resume` argument, which names the
session exactly, replacing a directory guess with an identity.

## Consequences

The guess this ADR wanted to avoid is still a guess, just a smaller one. A
process whose command line carries no session id can only be matched by
directory, several sessions can share one, and the best available answer is the
most recently active. That inference is confined to attaching a pid; it never
decides what a session *is* (ADR-0002).

Reading another user's process is denied by the kernel, which is what we want:
it means the process is not ours.

Jump-time resolution stays for sessions the scan could not match at all — a
transcript older than the read horizon whose agent is still running.
