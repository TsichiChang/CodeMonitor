# Plan: Code Session Monitor

## Context

The user runs multiple terminal coding agents — **Claude Code**, **Codex CLI**, and **OpenCode** — often several at once across different repos. They want an at-a-glance monitor answering: *how many sessions are active right now, and is each one **idle**, **running**, or **waiting for approval**?* The dashboard will live on a dedicated 7" secondary screen, so it must be glanceable and readable at a small resolution, and also reachable from the menu bar for quick checks.

Decisions locked from clarifying questions:
- **No GitHub / no sign-in** — purely local, offline, reads on-disk session data.
- **Both form factors** — a menu bar (tray) panel *and* a standalone dashboard window (primary surface, sized for a ~1024×600 7" screen).
- **Passive, zero-setup detection** — read session files + running processes only. No changes to the user's `~/.claude` config or hooks. Idle/running are accurate; "waiting for approval" is a documented heuristic.

## How detection works (verified on this machine)

**Source of truth = live agent processes.** A "session that exists right now" is a running `claude` / `codex` / `opencode` process. We enumerate them, map each to its working dir, correlate to its latest transcript, and classify state.

Per tool (all confirmed present on disk):

- **Claude Code** — transcripts at `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`. The dir name decodes to the cwd (e.g. `-Users-ziqizhang-Repos-WeeklyReport` → `/Users/ziqizhang/Repos/WeeklyReport`). Each line is a message; tailing the last line gives role + content types + timestamp.
- **Codex CLI** — rollouts at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. First line is `session_meta` with `cwd`, `git`, `model_provider`, `cli_version`. Last line events: `task_complete` = turn done; other events (`token_count`, tool calls) mid-turn = active.
- **OpenCode** — data under `~/.local/share/opencode/` (`opencode.db` + `storage/`). Best-effort: process presence + storage/db mtime for activity. Full transcript parsing is out of scope for v1 (SQLite); state shown as running/idle only, not waiting.

**Process → cwd mapping:** `ps` to list PIDs by command name; `lsof -a -p <pid> -d cwd -Fn` to read each process's working directory. Match cwd to the tool's latest session file for metadata.

**State classification (per session):**
- `running` — live process **and** transcript modified within the last few seconds (actively appending).
- `waiting` — live process, transcript idle for a few seconds, **and** last transcript entry is an assistant `tool_use` with no following `tool_result` (Claude Code) / a mid-turn event that isn't `task_complete` (Codex). Interpreted as blocked on a permission prompt. *(Heuristic — a genuinely long-running tool can also present this way; documented in-UI as "waiting".)*
- `idle` — live process, transcript idle, last entry is a completed assistant turn (`Stop` / `task_complete`) → agent finished, awaiting the user's next prompt.
- Sessions with **no** live process are not shown as active (optionally listed under a dimmed "recent" section using file mtime).

Poll every ~2s in the backend; push a fresh snapshot to the renderer over IPC.

## Architecture

Backend-required (file system + `ps`/`lsof` child processes + polling). Frontend renders the snapshot.

### Backend (`main/`)
- **`main/services/session-monitor.ts`** — core. `scanProcesses()` (ps + lsof), per-tool collectors (`collectClaude()`, `collectCodex()`, `collectOpencode()`) that read/tail session files, `classifyState()`, and `getSnapshot(): SessionSnapshot`. Uses safe `execFile` (no shell), bounded tail reads (read only the tail bytes of large JSONL, not whole files), and in-memory caching keyed by file path + mtime so unchanged transcripts aren't re-parsed. Follows `glaze-backend-performance` (child_process safety, polling, tail-read) and `glaze-backend-rules`.
- **`main/handlers/sessions.ts`** — IPC handlers (registered in `main/handlers/index.ts`):
  - `sessions:get-snapshot` → `SessionSnapshot`
  - `sessions:set-refresh-interval` → `{ ms: number }` (persisted setting)
  - Backend also pushes `sessions:snapshot` events on each poll (event emit → preload subscribe).
- **`main/index.ts`** — start the monitor's poll loop on app ready; create the **Tray** (menu bar icon whose title/color reflects worst state, e.g. red dot when any session is `waiting`) and the dashboard `BrowserWindow`. Follows `glaze-browser-window-recipes`, `glaze-app-lifecycle` (tray + menu-bar behavior, quit cleanup of the poll timer), and `glaze-window-sizing`.

**IPC contract (shared type in a `main/` + `renderer/` visible location, e.g. `main/services/types.ts` re-exported):**
```ts
type ToolKind = 'claude' | 'codex' | 'opencode';
type SessionState = 'running' | 'waiting' | 'idle';
interface SessionInfo {
  id: string;            // stable per session (pid+cwd or session uuid)
  tool: ToolKind;
  pid: number | null;
  cwd: string;           // working dir
  project: string;       // basename of cwd
  gitBranch?: string;
  model?: string;
  state: SessionState;
  lastActivity: number;  // epoch ms (transcript mtime / last ts)
  lastMessage?: string;  // short snippet for context
}
interface SessionSnapshot {
  sessions: SessionInfo[];
  counts: Record<SessionState, number>;
  generatedAt: number;
}
```

### Frontend (`renderer/`)
- **`renderer/main/home-view.tsx`** — the dashboard. Header with live counts (Running / Waiting / Idle badges + total). Grouped list of session cards (grouped by tool, or a flat grid), each card showing: tool icon, project/repo name, branch, model, a prominent color-coded **status pill**, relative last-activity time, and a truncated last-message line. Optimized for ~1024×600: large text, high contrast, generous status colors, works without scrolling for a handful of sessions. Subscribes to `sessions:snapshot` events (via a small `useSnapshot` hook) with `sessions:get-snapshot` for the initial load.
- **`renderer/preload.ts`** — expose the two invoke channels + the `sessions:snapshot` event subscription (`window.glazeAPI.sessions.*`). Verify against `defaultPreload` metadata; add narrow wrappers only.
- **Tray panel:** reuse the same components in a compact layout for the menu-bar dropdown (a second small `BrowserWindow` anchored to the tray, or the tray menu itself for a minimal list). Full detail lives in the dashboard window.
- Follows `glaze-frontend-rules`, `glaze-component-patterns` (semantic colors, `Text` variants, status pills), `glaze-icon-usage` (semantic-colored status icons).

### Config / packaging
- `package.json` — no new capabilities required for FS/child_process (backend Node). Add `glaze-window-sizing` defaults in `main/index.ts` (dashboard default ~1024×600, min ~640×480, resizable). No `ai` capability, no OAuth.
- State colors: `running` = green/active, `waiting` = amber/attention, `idle` = neutral/muted.

## Files to create / modify

- **Create** `main/services/session-monitor.ts`, `main/services/types.ts`, `main/handlers/sessions.ts`.
- **Modify** `main/handlers/index.ts` (register handlers), `main/index.ts` (poll loop, tray, window, sizing).
- **Modify** `renderer/preload.ts` (expose `sessions` namespace + event).
- **Rewrite** `renderer/main/home-view.tsx` (dashboard); add `renderer/components/session-card.tsx`, `renderer/components/status-pill.tsx`, and a `renderer/main/use-snapshot.ts` hook. Adjust `renderer/main/root-view.tsx`/`router.tsx` only as needed to land on the dashboard.

## Reuse

- Template's existing handler-registration pattern in `main/handlers/index.ts` and `app.ts`.
- `@glaze/core` design-system components (cards, `Text`, badges/pills, icons) — no hand-rolled CSS.
- Existing `renderer/main/router.tsx` routing scaffold.

## Verification

1. `npm run type-check && npm run lint`, then build once as the final step.
2. Open the app on the dashboard window. With the current environment there is at least one live Claude Code session (this one) — confirm it appears with the correct project name and a `running`/`waiting` pill that changes as the agent works vs. sits at a prompt.
3. Start a Codex and/or OpenCode session in another repo; confirm each appears under its tool with the right cwd/branch and state, and that closing the process removes it (or moves it to recent).
4. Trigger a permission prompt in a Claude Code session and confirm the card flips to **waiting** within ~2s; approve it and confirm it returns to **running**, then **idle** when the turn completes.
5. Confirm the menu-bar icon reflects the worst current state (e.g. amber/red when any session is waiting) and its panel lists sessions.
6. Live-inspect the dashboard DOM to verify counts, pills, and layout render correctly at the small window size.

## Notes / limitations (surface to user)

- "Waiting for approval" is a heuristic in passive mode; a long-running tool call can briefly look the same. Precise per-event detection would require installing Claude Code hooks (declined for now).
- OpenCode state is running/idle only in v1 (no transcript parse); can be deepened later by reading `opencode.db`.
