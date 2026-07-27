# Resolve live processes lazily, at jump time

Because a session's UUID cannot be recovered from a process (ADR-0002), matching
the two during every poll can only be a guess based on working directory — and
that guess is what produced phantom cards. It also cost a `ps` plus one `lsof`
per agent process every two seconds, purely to decorate cards with a pid nobody
reads.

Sessions are therefore listed from their tool's own records, without a pid. The
process is looked up only when the user actually jumps to a terminal, where a
wrong guess is visible and recoverable rather than silently corrupting the list.

## Consequences

`live` no longer props up state classification. It currently keeps a stalled
tool call in `waiting` rather than letting it decay to `idle`, so for tools
without an authoritative state channel the `waiting` window gets shorter. This
is acceptable only because those channels are the plan (ADR-0001); if Codex
stays on passive polling indefinitely, revisit this.

A session that exists only as a process — a freshly started agent that has not
written its first record — will not appear until it does.
