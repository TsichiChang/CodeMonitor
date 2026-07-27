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

**"…purely to decorate cards with a pid nobody reads."** The pid decides whether
a session is still open — a store can be quiet for hours while its agent sits
there alive, and without that signal such a session drops off the display it
exists to be seen on.

A third claim once stood here and was wrong: that the `--resume <uuid>` argument
in a process's command line identifies its session. It names the session being
resumed *from*. Resuming starts a new session with its own transcript, so
matching on argv attached a live pid to a finished session — which then never
aged out, because a session with a process never does. Measured on one pair: the
argv uuid's transcript was ten lines, untouched for seventeen hours, while the
session its own hook reported was at 1373 lines and still growing. Only a hook
can say which session a process is running.

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
