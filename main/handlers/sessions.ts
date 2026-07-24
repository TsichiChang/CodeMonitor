/**
 * Session monitor IPC handlers.
 *
 * Contract:
 *   sessions:get-snapshot        → SessionSnapshot (cached; cheap to poll)
 *   sessions:refresh             → SessionSnapshot (forces a fresh scan)
 *   sessions:set-refresh-interval ({ ms: number }) → { ms: number }
 *   sessions:get-refresh-interval → { ms: number }
 */

import { ipcMain, logger } from "@glaze/core/backend";

import { sessionMonitor } from "../services/session-monitor.js";
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
}

function readIntervalMs(arg: unknown): number | null {
  if (!arg || typeof arg !== "object") return null;
  const ms = (arg as { ms?: unknown }).ms;
  if (typeof ms !== "number" || !Number.isFinite(ms)) return null;
  if (ms < 500 || ms > 60_000) return null;
  return ms;
}
