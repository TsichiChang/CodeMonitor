import { Status } from "@glaze/core/components";

import type { SessionState } from "../lib/session-types";

const VARIANT: Record<SessionState, "success" | "warning" | "neutral"> = {
  running: "success",
  waiting: "warning",
  idle: "neutral",
};

const LABEL: Record<SessionState, string> = {
  running: "Running",
  waiting: "Waiting approval",
  idle: "Idle",
};

/** Color-coded live status indicator for a session's state. */
export function StatusPill({ state }: { state: SessionState }) {
  return (
    <Status variant={VARIANT[state]} className="text-small-strong">
      {LABEL[state]}
    </Status>
  );
}
