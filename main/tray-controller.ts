/**
 * Menu-bar (tray) controller for the Code Session Monitor.
 *
 * Shows a compact glance of session state in the macOS menu bar: the icon is
 * tinted by the most urgent state, the title shows the active count, and the
 * context menu lists sessions with an "Open Dashboard" action.
 */

import { Tray, Menu, logger, type MenuItemConstructorOptions } from "@glaze/core/backend";

import type { SessionSnapshot, SessionState } from "./services/types.js";

const STATE_GLYPH: Record<SessionState, string> = {
  running: "●",
  waiting: "⚠",
  idle: "○",
};

const STATE_LABEL: Record<SessionState, string> = {
  running: "Running",
  waiting: "Waiting",
  idle: "Idle",
};

let tray: Tray | null = null;

export function setupTray(onOpenDashboard: () => void): (snap: SessionSnapshot) => void {
  if (!tray) {
    try {
      tray = new Tray("terminal");
      tray.setToolTip("Code Session Monitor");
      tray.on("click", () => onOpenDashboard());
    } catch (err) {
      logger.warn("tray", "Failed to create tray", { err: String(err) });
      tray = null;
    }
  }

  return (snap: SessionSnapshot) => updateTray(snap, onOpenDashboard);
}

function updateTray(snap: SessionSnapshot, onOpenDashboard: () => void): void {
  if (!tray) return;
  const { counts, sessions } = snap;
  const total = sessions.length;

  // Icon tint reflects the most urgent state present.
  const color = counts.waiting > 0 ? "#F5A623" : counts.running > 0 ? "#34C759" : undefined;
  try {
    tray.setImage("terminal", color ? { color } : undefined);
  } catch {
    // Ignore transient image-set failures.
  }

  tray.setTitle(total > 0 ? String(total) : "", { fontType: "monospacedDigit" });
  tray.setToolTip(
    total === 0
      ? "No active sessions"
      : `${counts.running} running · ${counts.waiting} waiting · ${counts.idle} idle`,
  );

  const items: MenuItemConstructorOptions[] = [
    { label: "Code Sessions", enabled: false },
    { type: "separator" },
  ];

  if (total === 0) {
    items.push({ label: "No active sessions", enabled: false });
  } else {
    for (const s of sessions.slice(0, 20)) {
      items.push({
        label: `${STATE_GLYPH[s.state]}  ${s.project} — ${STATE_LABEL[s.state]}`,
        click: () => onOpenDashboard(),
      });
    }
  }

  items.push(
    { type: "separator" },
    { label: "Open Dashboard", click: () => onOpenDashboard() },
    { type: "separator" },
    { label: "Quit", role: "quit" },
  );

  tray.setContextMenu(Menu.buildFromTemplate(items));
}

export function destroyTray(): void {
  tray?.destroy();
  tray = null;
}
