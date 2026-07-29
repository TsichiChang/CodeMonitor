# Finishing is an event; waiting is a condition

The ambient band reports one thing: a session is blocked on you. ADR-0015
measured what that covers, and the answer is a tenth of the problem:

```
dead wait over a minute, user at the keyboard:  275 spells
  blocked on tool approval      24  ( 9%)   2.7h
  turn ended, awaiting you     251  (91%)  23.4h   ← no ambient signal at all
```

ADR-0018 dealt with the other nine tenths on the dashboard: a session that
finished while nobody was watching keeps its card and turns blue, because folding
it would play the most important thing that happens as a disappearance. But the
dashboard is the surface ADR-0014 was written because nobody looks at. The
signal that works — the one built precisely because the menu bar went unseen
through every one of those waits — says nothing about the category that costs
nine times more hours.

**The decision: when a session goes from `running` to finished-and-unseen, the
band breathes blue three times and stops.**

## Three breaths, not a lit band

The obvious shape — blue while any session is unread, the way amber is lit while
any session waits — does not work, and the reason is the distinction in the
title.

`waiting` is a *condition*. It persists, it costs wall-clock for as long as it
lasts, and the longer it runs the more it is worth interrupting for — which is
why the band's rate follows the longest current wait. Lighting it continuously
is right because the thing it reports is continuously true and continuously
expensive.

Unread is not like that. Sessions accumulate it and stay in it: finished work
sits unread until it is visited, and on a machine running three to five sessions
there is almost always at least one. A band lit on that condition would be lit
nearly always, and an indicator that is always on is one nobody sees — the exact
failure ADR-0014 diagnosed in the menu-bar icon, rebuilt at a larger size.

What carries information is not the condition but the **transition into it**: a
turn just ended, now, and it was not being watched. That is an event, it happens
at a moment, and a signal for it should occupy a moment.

## Why blue, and why the form says the same thing as the colour

Blue for unread is already taught by the cards (ADR-0018), and it was allowed
there on the grounds that it does not name a state — it says whose turn it is.
The band borrows the same word for the same meaning, so the two surfaces do not
have to be learned separately.

But peripheral vision reads colour poorly, and this now asks it to tell two
colours apart rather than to notice one. That is the cost, and the form is what
pays it: amber is **sustained and paced**, blue is **three breaths and gone**.
Even without resolving the hue, "it is still going" and "it stopped" are
distinguishable — which is ADR-0007's rule that colour must not be the only
channel carrying a distinction, applied to a surface that has exactly one.

## Amber outranks it

When something is already waiting, the blue is skipped rather than queued or
overlaid. The band is one channel; two colours in it would read as the amber
having ended, which is the one thing that must mean "your answer registered"
(ADR-0011's amendment). Waiting outranks unread everywhere else — it is
`attentionGroup` 0 against 2 — and the ordering does not change because the
surface did.

A blue event lost this way is not recovered later. By the time the amber clears,
"a turn just finished" is no longer true.

## It fires on the transition, never on the state

This is the whole implementation risk, and it has two known traps.

Launching the app must not fire anything. Every unread session is unread at
launch, and a band that flashed once per session on startup would be noise on
the surface that can least afford it. Only a session observed going from
`running` to unread counts — a session that is *already* unread the first time it
is seen is not an event, it is a backlog.

ADR-0021 sharpens that: a session is withheld until it has been seen twice, so
its first appearance on the display is never its first observation. The
transition has to be read from consecutive scans, the same shape as the turn
starts already tracked for the elapsed-time label, and a session appearing for
the first time has no previous state to have transitioned from.

## Unseen means not visually present, not merely in another application

A turn finishing in a session you are looking at should not fire this. Unread is
derived from *jumping* (ADR-0018), and sitting in a terminal is not jumping, so
the model does not know you were there — the band would repeat something the
screen already showed you.

The tempting guard is the application: suppress while the session's host app is
frontmost. It is wrong, and the reason is worth stating because it was believed
for a while. "In the same application" is not "visible". ADR-0009 records this
machine's actual topology — *"a tab can be split, and this machine runs three
sessions inside one of them"* — and a split tab shows you the pane that just
finished. Meanwhile the session two tabs over is equally "in the frontmost app"
and equally invisible; at best its tab carries a badge. App-level suppression
silences exactly the case worth signalling and keeps exactly the case that is
already on screen.

**So the question is visual co-location, and the unit that answers it is the
tab.** Suppress when the finished session sits in the active tab of a frontmost
host; fire otherwise, including for another tab of the same application.

The machinery exists. A hook records each session's tab (ADR-0009), Otty can be
asked which tab is active, and that is the same `tab list --json` the jump
already uses — measured there at 8ms. It runs on a transition, not per scan, so
it costs that once every few minutes rather than every two seconds.

Two fallbacks, both erring towards silence. A terminal that cannot be asked which
tab is active, or a session with no recorded tab, falls back to the application:
frontmost host suppresses. A desktop-hosted session (ADR-0017) has no tab to name
either, and the application is the only comparison available.

The check is approximate on both sides and cheaply so. A transition is noticed on
a scan — up to two seconds after the turn ended, fifteen if nothing else is
running — so it asks where the user is *then*, not at the moment the turn ended.

One thing was considered and not built. A hook fires `UserPromptSubmit` in the
session the user typed into, so "where the user last was" is knowable at that
moment — but only at that moment, and someone who typed in session A ten minutes
ago may have walked away. It is a heuristic about attention, which is what this
app spends its effort not guessing at.

## The same question, asked for a second purpose

"Can the user see this session right now?" turns out to have two consumers, and
the second one fixes a hole rather than adding a feature.

ADR-0018 made jumping the only thing that counts as reading. That was too narrow
and it went unnoticed because it is true of the only arrival this app can
*initiate*. Almost every real arrival is the user's own — ⌘1, a click on a tab,
⌘⇧[ — and none of them reach here. A session read by switching to its tab
therefore stayed unread indefinitely: blue, sorted above sessions that really
were unread, and still in the shortcut's queue. Queue consumption degrades into
random access, which is what ADR-0014 built the shortcut to replace.

So the predicate does double duty: where it is true, the band stays dark **and**
a visit is recorded. One meaning, one call, two consumers.

Nothing about ADR-0018's model reopens. Unread stays derived from
`lastActivity > lastVisited`; what grows is the set of observations that move
`lastVisited`. There is no flag, so there is still nothing that can forget to
clear one.

### Two consumers, two shapes

The band needs the answer **once, at a transition** — tens of times a day, which
is why a subprocess is affordable there. Clearing unread needs it **when the
user arrives**, and arrival fires no event: nothing in Otty pushes focus
changes, and its CLI only ever answers what is focused *now* (ADR-0009).

So this half is polled, and the poll is kept small by gating it on two free
checks before anything is spawned:

```
every ~15s, and only if
  ① some unread session has a recorded tab      — in memory, free
  ② and its host application is frontmost       — NSWorkspace, free, no permission
then spend one `otty-cli tab list --json`
```

Nothing is spent when the terminal is not in front, and nothing when nothing is
unread. The ceiling is a few thousand calls a day and the floor is zero. Fifteen
seconds of latency costs nothing, because the consumers are a blue dot and a
queue position — neither is worth a faster answer.

### It clears every session in the tab, deliberately

A split tab holding three sessions clears all three. That is the same visual
co-location argument as the suppression above, applied consistently: the unit is
what you *can see*, not what you happen to be looking at. Reading one pane of a
split while two others sit visible beside it is not a case where the other two
deserve to keep asking for attention.

Pane-level would be worse, not better. `active` on a pane is a property of one
pane per tab, so it would clear the focused pane and leave the two visible ones
beside it blue — precise about the wrong thing.

## What Accessibility would buy, and why it is not taken

Accessibility is the one API that would turn arrival into an event —
`kAXFocusedWindowChangedNotification` and its neighbours — and an event is what
removes the poll above. It is worth writing down why it is still not taken,
because the reasoning is not "we did not think of it".

**It gives the event and not the identity.** Accessibility sees UI structure:
windows, tab groups, titles, split groups. It cannot see a tty, a pid per pane,
or a session id. It would say "the focused window's selected tab changed", and
joining that to a hook-recorded tab id has no route except titles — which
ADR-0009 already found insufficient, when AppleScript's `processes` property
could tell that a tab was running an agent and still not separate two tabs
running the same one.

So it would replace the *timer*, not the subprocess: Accessibility for the
trigger, `otty-cli` for the identity. That is a genuinely better shape — perhaps
a hundred event-driven calls a day against a few thousand polled ones — and it
is still not worth the price.

**What it buys is about a minute of wall-clock a day, and latency on something
with no latency requirement.** A stale blue dot for fifteen seconds costs
nothing. **What it costs** is the most powerful permission on the system, on an
app whose rule is to ask for none it can avoid (ADR-0014, which named
Accessibility specifically while choosing Carbon for the shortcut). It is also
bound to the code signature the way Automation is, so an ad-hoc rebuild drops it
and the clearing simply stops, with nothing on screen to say so.

The generality argument — Accessibility works for every terminal, `otty-cli`
only for Otty — buys nothing here yet: every session on this machine reports
`TERM_PROGRAM=otty`. ADR-0013's rule applies, that a thing is claimed only where
it has been seen.

Three conditions would make it worth revisiting, and none of them is "it would
be tidier":

1. the fifteen-second lag is actually noticed — complained about once, not
   predicted;
2. sessions start running in terminals `otty-cli` cannot answer for, which
   breaks this route entirely rather than slowing it;
3. a third feature needs focus events too, so the permission stops being bought
   for one comfort.

## This may leave the signal rare, and that is not a failure

If dead wait happens mostly between panes of one split tab, this suppression
removes most of the firings and the blue band does almost nothing. That is a real
possibility, it is not being guessed at, and both outcomes are acceptable:

- the turn-ended class of dead wait falls — the signal was needed and works;
- blue almost never fires — the split-tab sessions were visible all along, there
  was no problem there, and what remains is the cross-tab and cross-application
  case, which is a narrower feature honestly scoped rather than a failed one.

## The numbers are eye judgements

Three, and the period, are not derived from anything. Three is the smallest count
that reads as a burst rather than as a single pulse or a pair that could be a
glitch, which is an argument for a floor and not for a value. The period should
start at the 1.2s a waiting card uses, so the two surfaces sound like one voice.

The swing must be the aggressive one. ADR-0014 records that a narrow swing on a
still edge went unnoticed entirely, and this has three breaths of exposure where
amber has minutes — if anything it needs more. `tools/band-probe.swift` is the
instrument for settling all of it, and it exists because these numbers were found
by running it and looking, not chosen on paper.

## How this gets falsified

The measurement is already built and already separates the two classes: the
table at the top is `tools/dead-wait.py`'s own output. So the test is narrower
than ADR-0014's — not "did dead wait fall" but **did the 251 spells and 23.4
hours of *turn ended, awaiting you* fall**, with the 24 approval waits as a
control that should not move.

**Suppression makes that reading ambiguous unless the firings are counted.** A
null result then has two explanations that call for opposite responses — the
signal fired and was not enough, or it was suppressed and never fired at all —
and nothing in the transcripts can tell them apart, because suppression happens
in the app and leaves no trace there. So every transition has to record what was
decided about it: fired, suppressed by tab, suppressed by application, skipped
for amber. `snapshotLog` is the precedent — off by default, diagnostic only,
appended by the running app because a second process that rescans cannot answer
a question about a moment (ADR-0021).

With that in hand the outcomes separate cleanly. Turn-ended dead wait falls: it
worked. It does not move while blue fired often: three breaths were not enough,
and the next question is whether anything transient can be, or whether this
category needs a persistence that unread cannot afford. It does not move because
blue almost never fired: the sessions were visible, and there was nothing here to
fix.

## Consequences

The band stops meaning one thing. It was "something is blocked on you"; it
becomes "something wants you", with the kind carried by colour and duration. That
is a real increase in what a glance-free surface has to encode, and it is spent
on the category that ADR-0015 measured as nine tenths of the cost.

Nothing else about the band changes. It still says nothing about *which* session
— identity still costs a glance, and the shortcut still answers it by arriving
(ADR-0014, ADR-0015). Blue is not an exception to that; it is the same claim
about a different queue.

`⌃⌥⌘J`'s ordering already matches: waiting, then running, then unread, then seen.
A blue burst and a press of the shortcut point at the same session without
anything new being written to make them agree.

The shortcut's queue starts draining on its own. Until now the only thing that
cleared a session out of it was jumping there through this app, so sessions read
by hand accumulated in front of the ones that had not been. That was the
shortcut quietly failing at the one thing it exists to do, and it was invisible
because nothing was wrong on screen — the cards were telling the truth about
what the app knew.

A subprocess returns to a timer, and that is worth naming rather than burying.
ADR-0003 measured `ps` plus an `lsof` per agent per poll at 115ms and replaced
the lot with libproc precisely to stop paying that, so putting an `otty-cli`
call back on a schedule runs against it. What makes it a different trade is the
gating: two free checks decide whether to spend anything, the cadence is
fifteen seconds rather than two, and the cost falls to zero whenever the
terminal is not in front or nothing is unread — none of which was available to
the process scan, which had to run every cycle no matter what.
