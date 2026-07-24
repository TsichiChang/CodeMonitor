import { useQuery } from "@tanstack/react-query";

import { emptySnapshot, type SessionSnapshot } from "../lib/session-types";

/**
 * Polls the backend for the current session snapshot. The backend keeps a
 * cached snapshot refreshed by its own timer, so this poll is cheap.
 */
export function useSnapshot() {
  return useQuery<SessionSnapshot>({
    queryKey: ["session-snapshot"],
    queryFn: () => window.glazeAPI.glaze.ipc.invoke<SessionSnapshot>("sessions:get-snapshot"),
    refetchInterval: 1500,
    refetchIntervalInBackground: true,
    placeholderData: (prev) => prev ?? emptySnapshot(),
  });
}
