/**
 * Steam's per-app display status (EDisplayStatus), as the library's Play/Update button reads it.
 * Numbers read from Steam's own source (see steam-cartridges `surfaces/install-state/core.ts`).
 */

/** States meaning "Steam wants to update or is updating this game". */
export const UPDATE_STATES: Readonly<Record<number, string>> = {
    6: "Updating",
    7: "Downloading",
    18: "UpdatePaused",
    19: "UpdateQueued",
    20: "UpdateRequired",
};

export const DISPLAY_STATUS_READY_TO_LAUNCH = 11;
export const DISPLAY_STATUS_UPDATE_REQUIRED = 20;

export function displayStatusName(ds: number | undefined): string {
    if (ds === undefined) return "unknown";
    if (ds === DISPLAY_STATUS_READY_TO_LAUNCH) return "ReadyToLaunch";
    if (ds === 4) return "Running";
    return UPDATE_STATES[ds] ?? String(ds);
}

export function isUpdateState(ds: number | undefined): boolean {
    return ds !== undefined && UPDATE_STATES[ds] !== undefined;
}

interface AppOverviewPartial {
    local_per_client_data?: {
        display_status?: number;
    };
}

export function liveDisplayStatus(appid: number): number | undefined {
    const store = (globalThis as unknown as {
        appStore?: { GetAppOverviewByAppID?: (id: number) => AppOverviewPartial | undefined };
    }).appStore;
    try {
        return store?.GetAppOverviewByAppID?.(appid)?.local_per_client_data?.display_status;
    } catch {
        return undefined;
    }
}
