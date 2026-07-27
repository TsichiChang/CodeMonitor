# Hooks report where they ran, not just what happened

Jumping to an Otty tab was matched by working directory, because Otty exposes no
per-tab tty or pid and its AppleScript `tty` property returns an empty string.
When two tabs sit in the same directory — currently two of this machine's three
— the jump could only guess.

A hook runs *inside* the session, which makes it the one place where the
terminal association is observable at all. Hooks therefore report terminal
context — the tty, and a terminal-specific id where one can be obtained — in
addition to state.

For Otty that id is captured by leaning on the model Otty actually has. Its CLI
knows only the *focused* pane: `jump` sends `cd` "to the focused pane", `learn`
records "the focused pane's current cwd". So the hook reads the focused window's
active tab at `UserPromptSubmit` — the one moment a session's tab is certainly
focused, because the user has just typed into it — and records that tab id
against the session.

## Considered options

`otty-cli pane show --pane current-pane` looks like exactly the right tool and
is not: `current-pane` is a value of the `quickTerminalCwd` setting ("follows
the focused pane"), not a pane selector, and an unrelated parse error mentioning
it is easy to misread as one. It fails identically inside and outside a pane.
Nothing in Otty resolves an *invoking* pane, so no amount of searching the CLI
will produce one.

Otty's AppleScript `processes` property does distinguish a tab running an agent
from an idle one, but it needs Automation permission (denied with -1743 in
testing) and still cannot separate two tabs both running the same agent.

What is captured is the *pane*, not the tab. A tab can be split, and this
machine runs three sessions inside one of them — so focusing the tab lands on
whichever of the three was last in front, which is the same ambiguity the whole
mechanism exists to remove. The tab is recorded alongside it as a fallback for
when the pane is gone.

A captured location is only accepted when its working directory matches the
session's origin directory. Otty learns a tab's directory from the OSC 7 sequence the
*shell* emits, and the shell is the agent's parent — so a tab's directory is
where the agent was started, regardless of any directory the agent moves to
afterwards. That makes it directly comparable to the session's Project
(ADR-0002), and a mismatch means we captured somebody else's tab.

## Consequences

The capture happens on `SessionStart` and on each user turn, never on tool-use
events: the tab a session lives in does not change between tool calls, and those
fire tens of times a minute inside the user's own agent. Collecting per turn is
also what lets a session that was already running when the hook was installed
get picked up — it needs only the user's next message.

The remaining assumption is about timing, not mechanism, and measurement makes
it small: `tab list` costs 8ms, and `window list` — only needed to disambiguate
multiple windows — another 8ms. Switching tabs inside a 8–16ms window is below
human motor response, so the failure mode is effectively unreachable. It is also
self-correcting: the next turn overwrites the record.

The directory guard cannot separate two tabs sitting in the same directory —
nothing can, over this interface — but it does reject a capture from the wrong
*project*, which is the damaging case. The cost is discarding an occasional
correct capture.

Sessions with no recorded tab still fall back to directory matching, so this
improves the common case without becoming a requirement.
