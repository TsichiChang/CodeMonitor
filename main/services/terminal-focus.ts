/**
 * Focus the terminal window/tab that hosts a coding-agent session.
 *
 * Given the session's process id we walk up the process tree to find the
 * hosting terminal application, then:
 *  - Terminal.app / iTerm2 / Otty: select the exact tab whose tty matches
 *    (AppleScript, which prompts for Automation permission the first time).
 *  - Any other known terminal: bring the app to the front via `open -b`
 *    (no permission prompt).
 */

import { execFile } from "child_process";
import { promisify } from "util";

import { logger } from "@glaze/core/backend";

const execFileAsync = promisify(execFile);
const OPTS = { timeout: 10_000, maxBuffer: 1024 * 1024 } as const;

export interface FocusResult {
  ok: boolean;
  reason?: "not-found" | "no-process" | "unknown-terminal" | "activate-failed";
}

interface TermApp {
  match: RegExp;
  /** AppleScript application name. */
  app: string;
  bundleId: string;
  kind: "terminal" | "iterm" | "otty" | "generic";
}

// Ordered most-specific first. `match` is tested against the full `ps` command.
const TERMINALS: TermApp[] = [
  { match: /iTerm\.app|iTerm2/i, app: "iTerm", bundleId: "com.googlecode.iterm2", kind: "iterm" },
  { match: /Terminal\.app/i, app: "Terminal", bundleId: "com.apple.Terminal", kind: "terminal" },
  { match: /[/\s]Otty(\s|$)/i, app: "Otty", bundleId: "io.appmakes.otty", kind: "otty" },
  { match: /WezTerm|wezterm/i, app: "WezTerm", bundleId: "com.github.wez.wezterm", kind: "generic" },
  { match: /Ghostty/i, app: "Ghostty", bundleId: "com.mitchellh.ghostty", kind: "generic" },
  { match: /kitty/i, app: "kitty", bundleId: "net.kovidgoyal.kitty", kind: "generic" },
  { match: /Alacritty/i, app: "Alacritty", bundleId: "org.alacritty", kind: "generic" },
  { match: /Warp\.app|stable\/warp/i, app: "Warp", bundleId: "dev.warp.Warp-Stable", kind: "generic" },
  { match: /Hyper\.app/i, app: "Hyper", bundleId: "co.zeit.hyper", kind: "generic" },
  { match: /Visual Studio Code|Code Helper|\/Code\.app/i, app: "Visual Studio Code", bundleId: "com.microsoft.VSCode", kind: "generic" },
];

async function ttyForPid(pid: number): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync("/bin/ps", ["-o", "tty=", "-p", String(pid)], OPTS);
    const t = stdout.trim();
    return t && t !== "??" ? t : null;
  } catch {
    return null;
  }
}

// Walk up the parent chain looking for a known terminal application.
async function findTerminalApp(pid: number): Promise<TermApp | null> {
  let current = pid;
  for (let i = 0; i < 12 && current > 1; i++) {
    let ppid = 0;
    let command = "";
    try {
      const { stdout } = await execFileAsync("/bin/ps", ["-o", "ppid=,command=", "-p", String(current)], OPTS);
      const m = stdout.trim().match(/^(\d+)\s+(.*)$/);
      if (!m) break;
      ppid = Number(m[1]);
      command = m[2];
    } catch {
      break;
    }
    const term = TERMINALS.find((t) => t.match.test(command));
    if (term) return term;
    if (!Number.isFinite(ppid) || ppid <= 1) break;
    current = ppid;
  }
  return null;
}

async function runOsa(script: string): Promise<boolean> {
  try {
    await execFileAsync("/usr/bin/osascript", ["-e", script], OPTS);
    return true;
  } catch (err) {
    logger.warn("terminal-focus", "osascript failed", { err: String(err) });
    return false;
  }
}

function terminalAppScript(devTty: string): string {
  return [
    'tell application "Terminal"',
    "  activate",
    "  set matched to false",
    "  repeat with w in windows",
    "    repeat with t in tabs of w",
    "      try",
    `        if (tty of t) is "${devTty}" then`,
    "          set selected tab of w to t",
    "          set index of w to 1",
    "          set matched to true",
    "          exit repeat",
    "        end if",
    "      end try",
    "    end repeat",
    "    if matched then exit repeat",
    "  end repeat",
    "end tell",
  ].join("\n");
}

function ottyScript(devTty: string): string {
  return [
    'tell application "Otty"',
    "  activate",
    "  set matched to false",
    "  repeat with w in windows",
    "    repeat with t in tabs of w",
    "      try",
    `        if (tty of t) is "${devTty}" then`,
    "          set selected of t to true",
    "          set index of w to 1",
    "          set matched to true",
    "          exit repeat",
    "        end if",
    "      end try",
    "    end repeat",
    "    if matched then exit repeat",
    "  end repeat",
    "end tell",
  ].join("\n");
}

function itermScript(devTty: string): string {
  return [
    'tell application "iTerm"',
    "  activate",
    "  repeat with w in windows",
    "    repeat with t in tabs of w",
    "      repeat with s in sessions of t",
    "        try",
    `          if (tty of s) is "${devTty}" then`,
    "            select s",
    "            select t",
    "            tell w to select",
    "            return",
    "          end if",
    "        end try",
    "      end repeat",
    "    end repeat",
    "  end repeat",
    "end tell",
  ].join("\n");
}

export async function focusTerminal(pid: number | null, ttyHint?: string | null): Promise<FocusResult> {
  if (!pid) return { ok: false, reason: "no-process" };

  const term = await findTerminalApp(pid);
  const tty = ttyHint ?? (await ttyForPid(pid));
  const devTty = tty ? (tty.startsWith("/dev/") ? tty : `/dev/${tty}`) : null;

  // Precise tab selection for the two scriptable terminals.
  if (devTty && term?.kind === "terminal" && (await runOsa(terminalAppScript(devTty)))) {
    return { ok: true };
  }
  if (devTty && term?.kind === "iterm" && (await runOsa(itermScript(devTty)))) {
    return { ok: true };
  }
  if (devTty && term?.kind === "otty" && (await runOsa(ottyScript(devTty)))) {
    return { ok: true };
  }

  // Fallback: bring the hosting app to the front (no Automation prompt).
  if (term) {
    try {
      await execFileAsync("/usr/bin/open", ["-b", term.bundleId], OPTS);
      return { ok: true };
    } catch (err) {
      logger.warn("terminal-focus", "open -b failed", { bundleId: term.bundleId, err: String(err) });
      return { ok: false, reason: "activate-failed" };
    }
  }

  return { ok: false, reason: "unknown-terminal" };
}
