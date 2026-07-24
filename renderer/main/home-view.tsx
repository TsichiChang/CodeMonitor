import { Badge, EmptyState, ScrollArea, Separator, Text } from "@glaze/core/components";

import { SessionCard, toolLabel } from "../components/session-card";
import type { SessionInfo, ToolKind } from "../lib/session-types";
import { useSnapshot } from "./use-snapshot";

const TOOL_ORDER: ToolKind[] = ["claude", "codex", "opencode"];

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
        <div className="flex items-center gap-2">
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
          <div className="flex flex-col gap-6 p-4">
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
      <div className="flex items-center gap-3">
        <Text variant="strong" color="secondary" className="uppercase tracking-wide text-small-strong">
          {toolLabel(tool)}
        </Text>
        <Text variant="small" color="tertiary" className="tabular-nums">
          {items.length}
        </Text>
        <Separator className="flex-1" />
      </div>
      <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(220px,1fr))]">
        {items.map((session) => (
          <SessionCard key={session.id} session={session} />
        ))}
      </div>
    </section>
  );
}
