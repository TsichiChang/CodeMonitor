/**
 * Shared types for the Code Session Monitor.
 * These describe the snapshot the backend produces and the renderer consumes.
 */

export type ToolKind = "claude" | "codex" | "opencode";

export type SessionState = "running" | "waiting" | "idle";

export interface SessionInfo {
  /** Stable identifier: `${tool}:${cwd}:${sessionId}`. */
  id: string;
  tool: ToolKind;
  /** OS process id when a live process was matched, otherwise null. */
  pid: number | null;
  /** Working directory of the session. */
  cwd: string;
  /** Human-friendly project label (basename of cwd). */
  project: string;
  gitBranch?: string;
  model?: string;
  state: SessionState;
  /** Whether a live agent process backs this session. */
  live: boolean;
  /** Epoch ms of the last observed activity (transcript mtime). */
  lastActivity: number;
  /** Short human snippet describing the latest activity. */
  lastMessage?: string;
}

export interface SessionSnapshot {
  sessions: SessionInfo[];
  counts: Record<SessionState, number>;
  /** Epoch ms the snapshot was generated. */
  generatedAt: number;
  /** True when process scanning (ps/lsof) succeeded this cycle. */
  processScanOk: boolean;
}

export function emptySnapshot(): SessionSnapshot {
  return {
    sessions: [],
    counts: { running: 0, waiting: 0, idle: 0 },
    generatedAt: Date.now(),
    processScanOk: false,
  };
}
