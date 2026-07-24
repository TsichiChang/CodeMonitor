import { Bot, Braces, GitBranch, SquareTerminal, type LucideIcon } from "lucide-react";

import { Text } from "@glaze/core/components";
import { cn } from "@glaze/core/utils";

import type { SessionInfo, ToolKind } from "../lib/session-types";
import { StatusPill } from "./status-pill";

const TOOL_ICON: Record<ToolKind, LucideIcon> = {
  claude: Bot,
  codex: Braces,
  opencode: SquareTerminal,
};

const TOOL_LABEL: Record<ToolKind, string> = {
  claude: "Claude Code",
  codex: "Codex",
  opencode: "OpenCode",
};

export function toolLabel(tool: ToolKind): string {
  return TOOL_LABEL[tool];
}

/** Small monochrome tool glyph, used in group headers. */
export function ToolIcon({ tool, className }: { tool: ToolKind; className?: string }) {
  const Icon = TOOL_ICON[tool];
  return <Icon className={className} />;
}

function shortModel(model: string): string {
  return model.replace(/^claude-/, "").replace(/^anthropic\//, "");
}

function relativeTime(ms: number): string {
  if (!ms) return "";
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h`;
  return `${Math.round(h / 24)}d`;
}

const STATE_BG: Record<SessionInfo["state"], string> = {
  running: "bg-support-green-10 dark:bg-support-green-20 hover:bg-support-green-20 dark:hover:bg-support-green-40",
  waiting: "bg-support-orange-10 dark:bg-support-orange-20 hover:bg-support-orange-20 dark:hover:bg-support-orange-40",
  idle: "bg-control-subtle hover:bg-control",
};

/**
 * A single session tile. Flat and airy: a hairline border, background tint
 * follows live state (green while running, amber while waiting), stronger in
 * dark mode where a light tint alone reads as invisible. Height is
 * fixed regardless of which optional fields a session has, so cards in a row
 * line up. Clicking jumps to the session's terminal.
 */
export function SessionCard({ session, onFocus }: { session: SessionInfo; onFocus: (id: string) => void }) {
  const meta = [session.gitBranch, session.model ? shortModel(session.model) : undefined].filter(Boolean);

  return (
    <button
      type="button"
      onClick={() => onFocus(session.id)}
      title="Jump to terminal"
      className={cn(
        "group relative text-left rounded-card border border-separator p-3.5 flex flex-col gap-2 min-w-0",
        "transition-colors hover:border-secondary",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent",
        STATE_BG[session.state],
      )}
    >
      <div className="flex items-baseline gap-2 min-w-0">
        <Text variant="strong" className="truncate">
          {session.project}
        </Text>
        <Text variant="small" color="tertiary" className="tabular-nums shrink-0 ml-auto">
          {relativeTime(session.lastActivity)}
        </Text>
      </div>

      <div className="flex items-center gap-1.5 min-w-0 min-h-3.5">
        {session.gitBranch && <GitBranch className="size-3.5 shrink-0 text-tertiary" />}
        {meta.length > 0 && (
          <Text variant="small" color="tertiary" className="truncate">
            {meta.join(" · ")}
          </Text>
        )}
      </div>

      <div className="flex items-center gap-2 min-w-0 mt-0.5">
        <StatusPill state={session.state} />
        {session.lastMessage && (
          <Text variant="small" color="tertiary" className="truncate min-w-0">
            {session.lastMessage}
          </Text>
        )}
      </div>
    </button>
  );
}
