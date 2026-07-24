/**
 * SessionMonitor - passively detects local coding-agent sessions
 * (Claude Code, Codex CLI, OpenCode) and classifies each as
 * running / waiting / idle.
 *
 * Strategy (zero-setup, no config changes):
 *  - Transcript files on disk are the primary source of truth. Each recent
 *    transcript = a session; its last entry + mtime classify the state.
 *  - Live processes (best-effort via ps/lsof) augment this: they confirm a
 *    session is still open and let us trust a long-lived "waiting" state.
 *
 * All heavy work is bounded: transcript tails are read (not whole files),
 * parsed results are cached by path+mtime, and child processes have
 * explicit maxBuffer + timeout.
 */

import { execFile } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { promisify } from "util";

import { logger } from "@glaze/core/backend";

import type { SessionInfo, SessionSnapshot, SessionState, ToolKind } from "./types.js";
import { emptySnapshot } from "./types.js";

const execFileAsync = promisify(execFile);

// ── Tunables ──────────────────────────────────────────────────────────
const WRITING_MS = 4_000; // transcript touched this recently ⇒ actively working
const WAITING_MAX_MS = 10 * 60_000; // beyond this, a stalled tool_use is treated as abandoned
const ACTIVE_WINDOW_MS = 30 * 60_000; // transcripts older than this are hidden unless a live process backs them
const TAIL_BYTES = 64 * 1024;
const HEAD_BYTES = 16 * 1024;
const CHILD_OPTS = { timeout: 8_000, maxBuffer: 8 * 1024 * 1024 } as const;

const HOME = os.homedir();

// ── Small JSON helpers (parsing untrusted transcript lines) ───────────
type Json = Record<string, unknown>;
function asObj(v: unknown): Json {
  return v && typeof v === "object" ? (v as Json) : {};
}
function asStr(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}
function asArr(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

// ── File tail / head readers (bounded) ────────────────────────────────
async function readTail(filePath: string, maxBytes = TAIL_BYTES): Promise<string> {
  const fh = await fs.promises.open(filePath, "r");
  try {
    const stat = await fh.stat();
    const start = Math.max(0, stat.size - maxBytes);
    const len = stat.size - start;
    if (len <= 0) return "";
    const buf = Buffer.alloc(len);
    await fh.read(buf, 0, len, start);
    return buf.toString("utf8");
  } finally {
    await fh.close();
  }
}

async function readHead(filePath: string, maxBytes = HEAD_BYTES): Promise<string> {
  const fh = await fs.promises.open(filePath, "r");
  try {
    const buf = Buffer.alloc(maxBytes);
    const { bytesRead } = await fh.read(buf, 0, maxBytes, 0);
    return buf.toString("utf8", 0, bytesRead);
  } finally {
    await fh.close();
  }
}

function lastJsonLine(text: string): Json | null {
  const lines = text.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line) continue;
    try {
      return asObj(JSON.parse(line));
    } catch {
      // The first line of a tail window can be truncated mid-record — skip it.
      continue;
    }
  }
  return null;
}

function firstJsonLine(text: string): Json | null {
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    try {
      return asObj(JSON.parse(line));
    } catch {
      return null;
    }
  }
  return null;
}

// ── Caches (bounded by the number of session files, which is small) ────
// session_meta never changes → cache permanently by path.
const codexMetaCache = new Map<string, Json | null>();
// tail parse keyed by path+mtime → invalidated when the file grows.
const tailCache = new Map<string, { mtimeMs: number; entry: Json | null }>();

async function cachedTail(filePath: string, mtimeMs: number): Promise<Json | null> {
  const hit = tailCache.get(filePath);
  if (hit && hit.mtimeMs === mtimeMs) return hit.entry;
  let entry: Json | null = null;
  try {
    entry = lastJsonLine(await readTail(filePath));
  } catch {
    entry = null;
  }
  tailCache.set(filePath, { mtimeMs, entry });
  // Keep the cache from growing without bound across a long-running session.
  if (tailCache.size > 500) tailCache.clear();
  return entry;
}

// ── State classification ──────────────────────────────────────────────
function classifyClaude(entry: Json | null, ageMs: number, live: boolean): SessionState {
  const msg = asObj(entry?.message);
  const role = asStr(msg.role) ?? asStr(entry?.role);
  const content = asArr(msg.content);
  const types = content.map((c) => asStr(asObj(c).type));
  const hasToolUse = types.includes("tool_use");
  const hasToolResult = types.includes("tool_result");

  if (role === "assistant" && hasToolUse) {
    if (ageMs < WRITING_MS) return "running";
    if (live || ageMs < WAITING_MAX_MS) return "waiting";
    return "idle";
  }
  if (role === "user" && hasToolResult) {
    return ageMs < WRITING_MS ? "running" : "idle";
  }
  if (role === "assistant") {
    // Completed a turn (text/thinking only) → awaiting the user.
    return ageMs < WRITING_MS ? "running" : "idle";
  }
  if (role === "user") {
    // Prompt just submitted → the model should be responding.
    return ageMs < WRITING_MS * 3 ? "running" : "idle";
  }
  return ageMs < WRITING_MS ? "running" : "idle";
}

function classifyCodex(entry: Json | null, ageMs: number, live: boolean): SessionState {
  const payloadType = asStr(asObj(entry?.payload).type) ?? asStr(entry?.type);
  if (payloadType === "task_complete") {
    return ageMs < WRITING_MS ? "running" : "idle";
  }
  // Any other trailing event means the turn is mid-flight.
  if (ageMs < WRITING_MS) return "running";
  if (live || ageMs < WAITING_MAX_MS) return "waiting";
  return "idle";
}

// ── Snippet extraction ────────────────────────────────────────────────
function claudeSnippet(entry: Json | null): string | undefined {
  const msg = asObj(entry?.message);
  const content = asArr(msg.content);
  for (const c of content) {
    const item = asObj(c);
    if (item.type === "text") return truncate(asStr(item.text));
    if (item.type === "tool_use") return truncate(`Using ${asStr(item.name) ?? "tool"}`);
    if (item.type === "tool_result") return "Tool finished";
  }
  if (asStr(msg.role) === "user" && typeof msg.content === "string") return truncate(msg.content);
  return undefined;
}

function codexSnippet(entry: Json | null): string | undefined {
  const payload = asObj(entry?.payload);
  const msg = asStr(payload.last_agent_message);
  if (msg) return truncate(msg);
  const type = asStr(payload.type) ?? asStr(entry?.type);
  return type ? truncate(type.replace(/_/g, " ")) : undefined;
}

function truncate(s: string | undefined, max = 100): string | undefined {
  if (!s) return undefined;
  const clean = s.replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

function basename(cwd: string): string {
  const b = path.basename(cwd);
  return b || cwd;
}

// ── Process scanning (best-effort) ────────────────────────────────────
interface LiveProc {
  tool: ToolKind;
  pid: number;
  cwd: string | null;
}

function toolFromCommand(command: string): ToolKind | null {
  if (/(?:^|\/)codex(?:\s|$)/.test(command)) return "codex";
  if (/(?:^|\/)opencode(?:\s|$)/.test(command)) return "opencode";
  if (/(?:^|\/)claude(?:\s|$)/.test(command) || /\.claude\/local\/.*(cli|claude)/.test(command)) return "claude";
  return null;
}

async function procCwd(pid: number): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], CHILD_OPTS);
    for (const line of stdout.split("\n")) {
      if (line.startsWith("n")) return line.slice(1).trim() || null;
    }
  } catch {
    // lsof unavailable or denied for this pid.
  }
  return null;
}

async function scanProcesses(): Promise<{ procs: LiveProc[]; ok: boolean }> {
  let stdout: string;
  try {
    ({ stdout } = await execFileAsync("/bin/ps", ["-axww", "-o", "pid=,command="], CHILD_OPTS));
  } catch (err) {
    logger.warn("session-monitor", "ps scan failed", { err: String(err) });
    return { procs: [], ok: false };
  }

  const matched: { pid: number; tool: ToolKind }[] = [];
  for (const raw of stdout.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    const sp = line.indexOf(" ");
    if (sp <= 0) continue;
    const pid = Number(line.slice(0, sp));
    const command = line.slice(sp + 1);
    if (!Number.isFinite(pid)) continue;
    const tool = toolFromCommand(command);
    if (tool) matched.push({ pid, tool });
  }

  const procs = await Promise.all(
    matched.map(async ({ pid, tool }) => ({ tool, pid, cwd: await procCwd(pid) })),
  );
  return { procs, ok: true };
}

// ── Claude Code collector ─────────────────────────────────────────────
async function collectClaude(liveCwds: Map<string, number>): Promise<SessionInfo[]> {
  const projectsDir = path.join(HOME, ".claude", "projects");
  let dirs: fs.Dirent[];
  try {
    dirs = await fs.promises.readdir(projectsDir, { withFileTypes: true });
  } catch {
    return [];
  }

  const now = Date.now();
  const out: SessionInfo[] = [];

  for (const dir of dirs) {
    if (!dir.isDirectory()) continue;
    const dirPath = path.join(projectsDir, dir.name);
    let files: string[];
    try {
      files = (await fs.promises.readdir(dirPath)).filter((f) => f.endsWith(".jsonl"));
    } catch {
      continue;
    }

    // Newest transcript in this project dir represents its current session.
    let newest: { file: string; mtimeMs: number } | null = null;
    for (const file of files) {
      try {
        const st = await fs.promises.stat(path.join(dirPath, file));
        if (!newest || st.mtimeMs > newest.mtimeMs) newest = { file, mtimeMs: st.mtimeMs };
      } catch {
        // skip unreadable file
      }
    }
    if (!newest) continue;

    const filePath = path.join(dirPath, newest.file);
    const ageMs = now - newest.mtimeMs;
    const entry = await cachedTail(filePath, newest.mtimeMs);
    // cwd: prefer the value recorded in the transcript, else decode the dir name.
    const cwd = asStr(entry?.cwd) ?? decodeClaudeCwd(entry, dir.name);
    const live = liveCwdMatch(liveCwds, cwd);
    if (ageMs > ACTIVE_WINDOW_MS && !live) continue;

    out.push({
      id: `claude:${cwd}:${newest.file.replace(/\.jsonl$/, "")}`,
      tool: "claude",
      pid: live?.pid ?? null,
      cwd,
      project: basename(cwd),
      gitBranch: asStr(entry?.gitBranch),
      model: asStr(asObj(entry?.message).model),
      state: classifyClaude(entry, ageMs, Boolean(live)),
      live: Boolean(live),
      lastActivity: newest.mtimeMs,
      lastMessage: claudeSnippet(entry),
    });
  }
  return out;
}

function decodeClaudeCwd(entry: Json | null, dirName: string): string {
  const fromEntry = asStr(entry?.cwd);
  if (fromEntry) return fromEntry;
  // Best-effort decode of the encoded project dir name back into a path.
  return dirName.replace(/-/g, "/");
}

// ── Codex collector ───────────────────────────────────────────────────
function codexDayDir(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return path.join(HOME, ".codex", "sessions", String(y), m, day);
}

async function collectCodex(liveCwds: Map<string, number>): Promise<SessionInfo[]> {
  const now = Date.now();
  const today = new Date(now);
  const yesterday = new Date(now - 24 * 60 * 60 * 1000);
  const out: SessionInfo[] = [];

  for (const dayDir of [codexDayDir(today), codexDayDir(yesterday)]) {
    let files: string[];
    try {
      files = (await fs.promises.readdir(dayDir)).filter((f) => f.startsWith("rollout-") && f.endsWith(".jsonl"));
    } catch {
      continue;
    }

    for (const file of files) {
      const filePath = path.join(dayDir, file);
      let mtimeMs: number;
      try {
        mtimeMs = (await fs.promises.stat(filePath)).mtimeMs;
      } catch {
        continue;
      }

      let meta = codexMetaCache.get(filePath);
      if (meta === undefined) {
        try {
          meta = firstJsonLine(await readHead(filePath));
        } catch {
          meta = null;
        }
        codexMetaCache.set(filePath, meta);
      }
      const payload = asObj(meta?.payload);
      const cwd = asStr(payload.cwd) ?? "unknown";
      const live = liveCwdMatch(liveCwds, cwd);
      const ageMs = now - mtimeMs;
      if (ageMs > ACTIVE_WINDOW_MS && !live) continue;

      const entry = await cachedTail(filePath, mtimeMs);
      const git = asObj(payload.git);
      out.push({
        id: `codex:${cwd}:${asStr(payload.id) ?? file}`,
        tool: "codex",
        pid: live?.pid ?? null,
        cwd,
        project: cwd === "unknown" ? "Codex session" : basename(cwd),
        gitBranch: asStr(git.branch),
        model: asStr(payload.model) ?? asStr(payload.model_provider),
        state: classifyCodex(entry, ageMs, Boolean(live)),
        live: Boolean(live),
        lastActivity: mtimeMs,
        lastMessage: codexSnippet(entry),
      });
    }
  }

  // Keep only the newest session per cwd (a cwd can accumulate rollout files).
  return dedupeNewestPerCwd(out);
}

// ── OpenCode collector (best-effort: process + storage activity) ───────
async function collectOpencode(procs: LiveProc[], now: number): Promise<SessionInfo[]> {
  const walPath = path.join(HOME, ".local", "share", "opencode", "opencode.db-wal");
  const dbPath = path.join(HOME, ".local", "share", "opencode", "opencode.db");
  let lastActivity = 0;
  for (const p of [walPath, dbPath]) {
    try {
      lastActivity = Math.max(lastActivity, (await fs.promises.stat(p)).mtimeMs);
    } catch {
      // missing file
    }
  }
  if (!lastActivity) return [];

  const ageMs = now - lastActivity;
  const stateFor = (): SessionState => (ageMs < WRITING_MS ? "running" : "idle");
  const liveProcs = procs.filter((p) => p.tool === "opencode");

  if (liveProcs.length > 0) {
    return liveProcs.map((p) => {
      const cwd = p.cwd ?? "unknown";
      return {
        id: `opencode:${cwd}:${p.pid}`,
        tool: "opencode" as const,
        pid: p.pid,
        cwd,
        project: cwd === "unknown" ? "OpenCode session" : basename(cwd),
        state: stateFor(),
        live: true,
        lastActivity,
        lastMessage: undefined,
      };
    });
  }

  // No live process — only surface if there was very recent activity.
  if (ageMs > ACTIVE_WINDOW_MS) return [];
  return [
    {
      id: "opencode:recent",
      tool: "opencode",
      pid: null,
      cwd: "unknown",
      project: "OpenCode session",
      state: stateFor(),
      live: false,
      lastActivity,
      lastMessage: undefined,
    },
  ];
}

// ── Merge helpers ─────────────────────────────────────────────────────
function liveCwdMatch(liveCwds: Map<string, number>, cwd: string): { pid: number } | null {
  const pid = liveCwds.get(cwd);
  return pid === undefined ? null : { pid };
}

function dedupeNewestPerCwd(sessions: SessionInfo[]): SessionInfo[] {
  const byCwd = new Map<string, SessionInfo>();
  for (const s of sessions) {
    const key = `${s.tool}:${s.cwd}`;
    const prev = byCwd.get(key);
    if (!prev || s.lastActivity > prev.lastActivity) byCwd.set(key, s);
  }
  return [...byCwd.values()];
}

const STATE_ORDER: Record<SessionState, number> = { waiting: 0, running: 1, idle: 2 };

// ── Monitor ───────────────────────────────────────────────────────────
class SessionMonitor {
  private latest: SessionSnapshot = emptySnapshot();
  private timer: ReturnType<typeof setInterval> | null = null;
  private intervalMs = 2_000;
  private onUpdate: ((snap: SessionSnapshot) => void) | null = null;
  private refreshing = false;

  async refresh(): Promise<SessionSnapshot> {
    if (this.refreshing) return this.latest;
    this.refreshing = true;
    try {
      const now = Date.now();
      const { procs, ok } = await scanProcesses();

      const liveByTool: Record<ToolKind, Map<string, number>> = {
        claude: new Map(),
        codex: new Map(),
        opencode: new Map(),
      };
      for (const p of procs) {
        if (p.cwd) liveByTool[p.tool].set(p.cwd, p.pid);
      }

      const [claude, codex, opencode] = await Promise.all([
        collectClaude(liveByTool.claude),
        collectCodex(liveByTool.codex),
        collectOpencode(procs, now),
      ]);

      const sessions = [...claude, ...codex, ...opencode];

      // Include live processes that produced no transcript session yet.
      for (const p of procs) {
        if (!p.cwd) continue;
        const exists = sessions.some((s) => s.tool === p.tool && s.cwd === p.cwd);
        if (exists) continue;
        sessions.push({
          id: `${p.tool}:${p.cwd}:${p.pid}`,
          tool: p.tool,
          pid: p.pid,
          cwd: p.cwd,
          project: basename(p.cwd),
          state: "running",
          live: true,
          lastActivity: now,
        });
      }

      sessions.sort((a, b) => {
        const s = STATE_ORDER[a.state] - STATE_ORDER[b.state];
        return s !== 0 ? s : b.lastActivity - a.lastActivity;
      });

      const counts: Record<SessionState, number> = { running: 0, waiting: 0, idle: 0 };
      for (const s of sessions) counts[s.state]++;

      this.latest = { sessions, counts, generatedAt: now, processScanOk: ok };
    } catch (err) {
      logger.error("session-monitor", "refresh failed", err);
    } finally {
      this.refreshing = false;
    }
    return this.latest;
  }

  getLatest(): SessionSnapshot {
    return this.latest;
  }

  start(intervalMs: number, onUpdate: (snap: SessionSnapshot) => void): void {
    this.intervalMs = Math.max(500, intervalMs);
    this.onUpdate = onUpdate;
    this.stop();
    const tick = async () => {
      const snap = await this.refresh();
      this.onUpdate?.(snap);
    };
    void tick();
    this.timer = setInterval(() => void tick(), this.intervalMs);
  }

  setInterval(intervalMs: number): void {
    if (this.onUpdate) this.start(intervalMs, this.onUpdate);
    else this.intervalMs = Math.max(500, intervalMs);
  }

  getInterval(): number {
    return this.intervalMs;
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }
}

export const sessionMonitor = new SessionMonitor();
