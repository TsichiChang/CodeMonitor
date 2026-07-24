// Renderer-side mirror of the backend session snapshot contract
// (main/services/types.ts). Type-only; kept in sync manually.

export type ToolKind = "claude" | "codex" | "opencode";

export type SessionState = "running" | "waiting" | "idle";

export interface SessionInfo {
  id: string;
  tool: ToolKind;
  pid: number | null;
  cwd: string;
  project: string;
  gitBranch?: string;
  model?: string;
  state: SessionState;
  live: boolean;
  lastActivity: number;
  lastMessage?: string;
}

export interface SessionSnapshot {
  sessions: SessionInfo[];
  counts: Record<SessionState, number>;
  generatedAt: number;
  processScanOk: boolean;
}

export function emptySnapshot(): SessionSnapshot {
  return {
    sessions: [],
    counts: { running: 0, waiting: 0, idle: 0 },
    generatedAt: 0,
    processScanOk: false,
  };
}
