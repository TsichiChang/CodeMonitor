import { Badge, EmptyState, ScrollArea, Separator, Text, toast } from "@glaze/core/components";

import { SessionCard, ToolIcon, toolLabel } from "../components/session-card";
import type { FocusResult, SessionInfo, ToolKind } from "../lib/session-types";
import { useSnapshot } from "./use-snapshot";

const TOOL_ORDER: ToolKind[] = ["claude", "codex", "opencode"];

async function focusSession(id: string) {
  try {
    const result = await window.glazeAPI.glaze.ipc.invoke<FocusResult>("sessions:focus-terminal", { id });
    if (!result.ok) {
      toast.error(
        result.reason === "unknown-terminal"
          ? "Couldn't identify the terminal app for this session."
          : "Couldn't find the terminal window for this session.",
      );
    }
  } catch {
    toast.error("Couldn't jump to the terminal.");
  }
}

export function HomeView() {
  const { data } = useSnapshot();
  const snapshot = data ?? {
    sessions: [],
    counts: { running: 0, waiting: 0, idle: 0 },
    generatedAt: 0,
    processScanOk: false,
  };
  const { sessions, counts } = snapshot;

  const groups = TOOL_ORDER.map((tool) => ({
    tool,
    items: sessions.filter((s) => s.tool === tool),
  })).filter((g) => g.items.length > 0);

  return (
    <ScrollArea
      title="Code Sessions"
      actions={
        <div className="flex items-center gap-1.5">
          <Badge color="green" size="medium">
            {counts.running} running
          </Badge>
          <Badge color="orange" size="medium">
            {counts.waiting} waiting
          </Badge>
          <Badge color="secondary" size="medium">
            {counts.idle} idle
          </Badge>
        </div>
      }
      className="h-full"
    >
      <div className="relative min-h-full">
        {sessions.length === 0 ? (
          <EmptyState
            title="No active sessions"
            description="Start a Claude Code, Codex, or OpenCode session in a terminal and it will appear here."
          />
        ) : (
          <div className="flex flex-col gap-7 px-5 py-4">
            {groups.map((group) => (
              <ToolGroup key={group.tool} tool={group.tool} items={group.items} />
            ))}
          </div>
        )}
      </div>
    </ScrollArea>
  );
}

function ToolGroup({ tool, items }: { tool: ToolKind; items: SessionInfo[] }) {
  return (
    <section className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <ToolIcon tool={tool} className="size-4 shrink-0 text-tertiary" />
        <Text color="tertiary" className="uppercase tracking-wide text-small-strong">
          {toolLabel(tool)}
        </Text>
        <Text variant="small" color="tertiary" className="tabular-nums">
          {items.length}
        </Text>
        <Separator className="flex-1" />
      </div>
      <div className="grid gap-2.5 items-start grid-cols-[repeat(auto-fill,minmax(240px,1fr))]">
        {items.map((session) => (
          <SessionCard key={session.id} session={session} onFocus={focusSession} />
        ))}
      </div>
    </section>
  );
}
