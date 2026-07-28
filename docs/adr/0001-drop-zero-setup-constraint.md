# Drop the zero-setup constraint

The scanner was built on an explicit "zero-setup, no config changes" principle:
detect everything passively from files and processes, never touch the user's
tool configuration. The cost is that session state is inferred — "waiting for
approval" is guessed from a tool call sitting unanswered for 45 seconds — and
inferred state is too unreliable to notify on.

Every tool we monitor exposes an authoritative channel we were ignoring: Claude
Code fires hooks (including `PermissionRequest`), Codex has a `notify` command
plus a hooks feature, and OpenCode records sessions in SQLite. We are dropping
the constraint so we can consume these, keeping passive detection as the floor
so an unconfigured machine still works.

> **On Codex, only the hooks.** `notify` turned out to be one command per
> installation — `config.toml` holds a single entry — so registering there
> evicts whatever already uses it instead of joining it. On this machine that
> was Codex Computer Use. The hook arrays coexist the way Claude's do, and the
> four events Codex fires (`SessionStart`, `UserPromptSubmit`, `Stop`,
> `PermissionRequest`) are a subset of Claude's with the same meanings, so they
> needed no new interpretation. What Codex has no equivalent of is
> `PreToolUse`/`PostToolUse`, so a turn is reported at its edges only.

## Consequences

Installing a hook means writing to a config file the user owns, so it must be
opt-in and must append rather than replace — this machine already has three
hooks registered per Claude event, and clobbering them would break other tools.

Claude Code and Codex turn out to share the same hook shape: an event name maps
to an array of entries, so both are safely appendable. Codex reads
`~/.codex/hooks.json` (gated behind `features.hooks`, already enabled) and
exposes `PermissionRequest`, `SessionStart`, `Stop` and `UserPromptSubmit` —
enough for authoritative state. Codex's single-slot `notify` command, which is
already occupied by another application, is therefore not the integration point
and can be left alone.

Otty tags the entries it owns with `"_otty": true`. Adopting the same
convention is what makes an installed hook safely upgradable and removable
later, rather than something that accumulates duplicates.

OpenCode needs no hook: its SQLite store already carries per-session state.
