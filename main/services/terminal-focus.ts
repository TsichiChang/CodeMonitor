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

// Run an AppleScript and return its trimmed stdout, or null if it errored
// (e.g. Automation permission denied). Selection scripts return "matched" when
// they found and focused the target tab, "nomatch" otherwise.
async function runOsaResult(script: string): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync("/usr/bin/osascript", ["-e", script], OPTS);
    return stdout.trim();
  } catch (err) {
    logger.warn("terminal-focus", "osascript failed", { err: String(err) });
    return null;
  }
}

// True if the app is running WITHOUT launching it (`is running` never launches).
// Used to gate tty probes so we never spring an idle terminal to life.
async function isRunning(appName: string): Promise<boolean> {
  const res = await runOsaResult(`application "${appName}" is running`);
  return res === "true";
}

function terminalAppScript(devTty: string): string {
  return [
    'tell application "Terminal"',
    "  repeat with w in windows",
    "    repeat with t in tabs of w",
    "      try",
    `        if (tty of t) is "${devTty}" then`,
    "          set selected tab of w to t",
    "          try",
    "            set index of w to 1",
    "          end try",
    "          activate",
    '          return "matched"',
    "        end if",
    "      end try",
    "    end repeat",
    "  end repeat",
    "end tell",
    'return "nomatch"',
  ].join("\n");
}

function ottyScript(devTty: string): string {
  return [
    'tell application "Otty"',
    "  repeat with w in windows",
    "    repeat with t in tabs of w",
    "      try",
    `        if (tty of t) is "${devTty}" then`,
    "          set selected of t to true",
    "          try",
    "            set index of w to 1",
    "          end try",
    "          activate",
    '          return "matched"',
    "        end if",
    "      end try",
    "    end repeat",
    "  end repeat",
    "end tell",
    'return "nomatch"',
  ].join("\n");
}

function itermScript(devTty: string): string {
  return [
    'tell application "iTerm"',
    "  repeat with w in windows",
    "    repeat with t in tabs of w",
    "      repeat with s in sessions of t",
    "        try",
    `          if (tty of s) is "${devTty}" then`,
    "            select s",
    "            select t",
    "            tell w to select",
    "            activate",
    '            return "matched"',
    "          end if",
    "        end try",
    "      end repeat",
    "    end repeat",
    "  end repeat",
    "end tell",
    'return "nomatch"',
  ].join("\n");
}

function scriptFor(kind: TermApp["kind"], devTty: string): string | null {
  switch (kind) {
    case "terminal":
      return terminalAppScript(devTty);
    case "iterm":
      return itermScript(devTty);
    case "otty":
      return ottyScript(devTty);
    default:
      return null;
  }
}

export async function focusTerminal(pid: number | null, ttyHint?: string | null): Promise<FocusResult> {
  if (!pid) return { ok: false, reason: "no-process" };

  const term = await findTerminalApp(pid);
  const tty = ttyHint ?? (await ttyForPid(pid));
  const devTty = tty ? (tty.startsWith("/dev/") ? tty : `/dev/${tty}`) : null;

  // Precise tab selection driven by tty, NOT the process tree: terminals like
  // Otty spawn shells from a daemon/CLI layer that is reparented away from the
  // GUI process, so walking ppid never finds them. Instead we ask each running
  // scriptable terminal whether it owns a tab with this tty. Only the true host
  // matches (tty is unique), so non-hosts return "nomatch" without activating.
  // Probe the process-tree-detected terminal first when it is scriptable, then
  // the rest as a fallback.
  if (devTty) {
    const scriptable = TERMINALS.filter((t) => scriptFor(t.kind, devTty) !== null);
    const ordered = term && scriptFor(term.kind, devTty) ? [term, ...scriptable.filter((t) => t !== term)] : scriptable;
    for (const cand of ordered) {
      if (!(await isRunning(cand.app))) continue;
      const script = scriptFor(cand.kind, devTty);
      if (!script) continue;
      const res = await runOsaResult(script);
      if (res === "matched") return { ok: true };
      // "nomatch" → not the host, keep probing; null → script error (e.g.
      // permission denied), fall through to the open -b fallback below.
    }
  }

  // Fallback: bring the hosting app to the front (no precise tab, no prompt).
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
