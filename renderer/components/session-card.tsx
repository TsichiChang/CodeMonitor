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

/**
 * A single session tile. Flat and airy: a hairline border, no fill, a subtle
 * amber accent for the one state that needs attention. Clicking jumps to the
 * session's terminal.
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
        "transition-colors hover:bg-control-subtle hover:border-secondary",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent",
      )}
    >
      {session.state === "waiting" && (
        <span aria-hidden className="absolute left-0 top-3 bottom-3 w-0.5 rounded-full bg-support-orange-60" />
      )}

      <div className="flex items-baseline gap-2 min-w-0">
        <Text variant="strong" className="truncate">
          {session.project}
        </Text>
        <Text variant="small" color="tertiary" className="tabular-nums shrink-0 ml-auto">
          {relativeTime(session.lastActivity)}
        </Text>
      </div>

      {meta.length > 0 && (
        <div className="flex items-center gap-1.5 min-w-0">
          {session.gitBranch && <GitBranch className="size-3.5 shrink-0 text-tertiary" />}
          <Text variant="small" color="tertiary" className="truncate">
            {meta.join(" · ")}
          </Text>
        </div>
      )}

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
