# The ambient signal carries no content

ADR-0014 established that the band says nothing about *which* session waits.
This is the same answer to a second, more tempting question: it says nothing
about *what* the session wants either — not the tool awaiting approval, not the
question just asked. The temptation is real; another Claude Code notch app,
`CurroTech/claude-island`, is built around exactly this ("approval triage") and
carries the whole hook payload for it, as does Otty's own built-in integration,
which already passes `context-b64` on `PermissionRequest`. **The data is
available on this machine today. It is not used because it is not worth its
cost, not because it cannot be had.**

Two weeks of transcripts split dead wait like this:

```
dead wait over a minute, user at the keyboard:  275 spells
  blocked on tool approval      24  ( 9%)   2.7h   ← has an action to show
  turn ended, awaiting you     251  (91%)  23.4h   ← has no action to show
```

So a signal built around pending approvals addresses a tenth of the problem, and
within that tenth three quarters of the tools are `Bash`, whose name alone says
nothing. Approval triage is a real feature; it is not this user's bottleneck.

## Content does not remove the trip

The remaining nine tenths are turns that finished and are waiting on a reply, and
the cost of one breaks into four parts: not noticing, switching over, reading the
output, thinking and typing. Content on the band cannot touch the last two — the
output still has to be read where it lives — and it does not remove the switch
either: knowing that `Bash: rm -rf build/` is pending still leaves the `y` to be
pressed in that terminal.

What content buys, in both classes of wait, is a couple of seconds of
comprehension after arriving. What it costs is text on a surface that exists
precisely because it does not have to be read, on a display where motion and
attention are the scarce resources (ADR-0006). The urgency the band already
encodes — how long the wait has run — is what decides *when* to go, and that is
the only decision made before arriving.

## Replying without going there is the real lever, and it waits for evidence

The one thing that would delete the switch is answering in place, and it is
cheap to build: Otty exposes `pane capture` to read the output and
`pane send-text` to send a reply, both without any permission. Replies are short
enough for it — 43% are twenty characters or less, 81% under a hundred and
twenty.

It is deferred anyway, because the four-part cost above is dominated by *not
noticing*, and the band aimed at that has not been measured yet. If a week of
`tools/dead-wait.py` shows 7.6 falling to one or two, the problem a reply panel
would address is a much smaller one. If it does not fall, the next question is
which part failed — still not noticing (change the signal, not add a panel) or
noticing and not bothering to switch (then build the panel). Adding it now is
guessing at an unmeasured problem, which this codebase has already paid for once
today.
