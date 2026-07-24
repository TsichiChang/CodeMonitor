/**
 * Session monitor IPC handlers.
 *
 * Contract:
 *   sessions:get-snapshot        → SessionSnapshot (cached; cheap to poll)
 *   sessions:refresh             → SessionSnapshot (forces a fresh scan)
 *   sessions:set-refresh-interval ({ ms: number }) → { ms: number }
 *   sessions:get-refresh-interval → { ms: number }
 *   sessions:focus-terminal      ({ id: string }) → { ok: boolean; reason?: string }
 */

import { ipcMain, logger } from "@glaze/core/backend";

import { sessionMonitor } from "../services/session-monitor.js";
import type { FocusResult } from "../services/terminal-focus.js";
import type { SessionSnapshot } from "../services/types.js";

export function registerSessionHandlers(): void {
  ipcMain.handle("sessions:get-snapshot", async (): Promise<SessionSnapshot> => {
    return sessionMonitor.getLatest();
  });

  ipcMain.handle("sessions:refresh", async (): Promise<SessionSnapshot> => {
    return sessionMonitor.refresh();
  });

  ipcMain.handle("sessions:get-refresh-interval", async (): Promise<{ ms: number }> => {
    return { ms: sessionMonitor.getInterval() };
  });

  ipcMain.handle("sessions:set-refresh-interval", async (_event, arg: unknown): Promise<{ ms: number }> => {
    const ms = readIntervalMs(arg);
    if (ms === null) {
      throw new Error("sessions:set-refresh-interval requires { ms: number } between 500 and 60000");
    }
    sessionMonitor.setInterval(ms);
    logger.info("sessions", "Refresh interval updated", { ms });
    return { ms: sessionMonitor.getInterval() };
  });

  ipcMain.handle("sessions:focus-terminal", async (_event, arg: unknown): Promise<FocusResult> => {
    const id = readId(arg);
    if (!id) {
      throw new Error("sessions:focus-terminal requires { id: string }");
    }
    const result = await sessionMonitor.focusSession(id);
    logger.info("sessions", "Focus terminal requested", { id, ok: result.ok, reason: result.reason });
    return result;
  });
}

function readId(arg: unknown): string | null {
  if (!arg || typeof arg !== "object") return null;
  const id = (arg as { id?: unknown }).id;
  return typeof id === "string" && id.length > 0 ? id : null;
}

function readIntervalMs(arg: unknown): number | null {
  if (!arg || typeof arg !== "object") return null;
  const ms = (arg as { ms?: unknown }).ms;
  if (typeof ms !== "number" || !Number.isFinite(ms)) return null;
  if (ms < 500 || ms > 60_000) return null;
  return ms;
}
