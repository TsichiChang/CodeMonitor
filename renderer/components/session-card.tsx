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

function relativeTime(ms: number): string {
  if (!ms) return "";
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
}

/** A single session tile. Waiting sessions get a tinted surface to draw the eye. */
export function SessionCard({ session }: { session: SessionInfo }) {
  const Icon = TOOL_ICON[session.tool];

  return (
    <div
      className={cn(
        "rounded-card p-4 flex flex-col gap-2 min-w-0",
        session.state === "waiting" ? "bg-support-orange-10" : "bg-well",
      )}
    >
      <div className="flex items-center gap-2 min-w-0">
        <Icon className="size-4 shrink-0 text-tertiary" />
        <Text variant="strong" className="truncate">
          {session.project}
        </Text>
      </div>

      {(session.gitBranch || session.model) && (
        <div className="flex items-center gap-1.5 min-w-0">
          {session.gitBranch && (
            <>
              <GitBranch className="size-3.5 shrink-0 text-tertiary" />
              <Text variant="small" color="tertiary" className="truncate">
                {session.gitBranch}
              </Text>
            </>
          )}
          {session.model && (
            <Text variant="small" color="tertiary" className="truncate">
              {session.gitBranch ? `· ${session.model}` : session.model}
            </Text>
          )}
        </div>
      )}

      <div className="flex items-center justify-between gap-2 mt-1">
        <StatusPill state={session.state} />
        <Text variant="small" color="tertiary" className="tabular-nums shrink-0">
          {relativeTime(session.lastActivity)}
        </Text>
      </div>

      {session.lastMessage && (
        <Text variant="small" color="secondary" className="truncate">
          {session.lastMessage}
        </Text>
      )}
    </div>
  );
}
