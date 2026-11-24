export interface HistoryEntry {
    buildid: string;
    date: number;
    depots: Record<string, string>;
    seenAt?: number;
}

export interface CustomVersionEntry {
    depotId: string;
    manifestId: string;
    addedAt?: number;
}

export interface GameFreezeStatus {
    found: boolean;
    appid: number;
    name?: string;
    manifestPath?: string;
    frozen: boolean;
    frozenAt?: number;
    readonly: boolean;
    installedBuildId?: string;
    installedDate?: number;
    installedDepots?: Record<string, string>;
    manifestBuildId?: string;
    targetBuildId?: string;
    stateFlags?: number;
    bytesToDownload?: number;
    autoUpdateBehavior?: number;
    betakey?: string;
    spoofedBuildId?: string;
    history: HistoryEntry[];
    customVersions: CustomVersionEntry[];
    error?: string;
}

export interface SyncResult {
    synced: boolean;
    reason?: string;
    error?: string;
    status?: GameFreezeStatus;
}

/** Guardrail 21: Lua encodes empty tables as `{}` (object), never `[]`. */
export function asArray<T>(val: unknown): T[] {
    return Array.isArray(val) ? (val as T[]) : [];
}

function asRecord(val: unknown): Record<string, string> {
    if (!val || typeof val !== "object" || Array.isArray(val)) return {};
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(val as Record<string, unknown>)) {
        if (typeof v === "string") out[k] = v;
    }
    return out;
}

function normalizeStatus(raw: unknown): GameFreezeStatus {
    const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
    return {
        found: r["found"] === true,
        appid: Number(r["appid"]) || 0,
        name: typeof r["name"] === "string" ? r["name"] : undefined,
        manifestPath: typeof r["manifestPath"] === "string" ? r["manifestPath"] : undefined,
        frozen: r["frozen"] === true,
        frozenAt: Number(r["frozenAt"]) || 0,
        readonly: r["readonly"] === true,
        installedBuildId: typeof r["installedBuildId"] === "string" ? r["installedBuildId"] : undefined,
        installedDate: Number(r["installedDate"]) || 0,
        installedDepots: asRecord(r["installedDepots"]),
        manifestBuildId: typeof r["manifestBuildId"] === "string" ? r["manifestBuildId"] : undefined,
        targetBuildId: typeof r["targetBuildId"] === "string" ? r["targetBuildId"] : undefined,
        stateFlags: Number(r["stateFlags"]) || 0,
        bytesToDownload: Number(r["bytesToDownload"]) || 0,
        autoUpdateBehavior: Number(r["autoUpdateBehavior"]) || 0,
        betakey: typeof r["betakey"] === "string" ? r["betakey"] : "public",
        spoofedBuildId: typeof r["spoofedBuildId"] === "string" ? r["spoofedBuildId"] : undefined,
        history: asArray<HistoryEntry>(r["history"]).map((h) => ({
            buildid: typeof h?.buildid === "string" ? h.buildid : "",
            date: Number(h?.date) || 0,
            depots: asRecord(h?.depots),
            seenAt: Number(h?.seenAt) || 0,
        })),
        customVersions: asArray<CustomVersionEntry>(r["customVersions"]).map((c) => ({
            depotId: typeof c?.depotId === "string" ? c.depotId : "",
            manifestId: typeof c?.manifestId === "string" ? c.manifestId : "",
            addedAt: Number(c?.addedAt) || 0,
        })).filter((c) => c.depotId !== "" && c.manifestId !== ""),
        error: typeof r["error"] === "string" ? r["error"] : undefined,
    };
}

async function callRpc<R>(method: string, payload: object = {}): Promise<R> {
    const millennium = (window as unknown as {
        Millennium?: {
            callServerMethod?: (plugin: string, name: string, args: { payload: string }) => Promise<string>;
        };
    }).Millennium;
    const callFn = millennium?.callServerMethod;
    if (typeof callFn !== "function") {
        throw new Error("Millennium.callServerMethod is unavailable");
    }
    const candidates = ["steam-timefreeze-dev", "steam-timefreeze"];
    let lastError: unknown;
    for (const plugin of candidates) {
        try {
            const raw = await callFn.call(millennium, plugin, method, {
                payload: JSON.stringify(payload),
            });
            return JSON.parse(raw) as R;
        } catch (err) {
            lastError = err;
            if (String(err).includes("plugin not running")) {
                continue;
            }
            throw err;
        }
    }
    throw lastError;
}

export const backend = {
    async getStatus(appid: number): Promise<GameFreezeStatus> {
        const res = await callRpc<unknown>("TimefreezeGetStatus", { appid });
        return normalizeStatus(res);
    },

    async freeze(
        appid: number,
        latestBuildId: string,
        latestDepots: Record<string, string>,
    ): Promise<GameFreezeStatus> {
        const res = await callRpc<unknown>("TimefreezeFreeze", {
            appid,
            latestBuildId,
            latestDepots,
        });
        return normalizeStatus(res);
    },

    async unfreeze(appid: number): Promise<GameFreezeStatus> {
        const res = await callRpc<unknown>("TimefreezeUnfreeze", { appid });
        return normalizeStatus(res);
    },

    async syncFrozen(
        appid: number,
        latestBuildId: string,
        latestDepots: Record<string, string>,
    ): Promise<SyncResult> {
        const res = await callRpc<Record<string, unknown>>("TimefreezeSyncFrozen", {
            appid,
            latestBuildId,
            latestDepots,
        });
        return {
            synced: res?.["synced"] === true,
            reason: typeof res?.["reason"] === "string" ? res["reason"] : undefined,
            error: typeof res?.["error"] === "string" ? res["error"] : undefined,
            status: res?.["status"] ? normalizeStatus(res["status"]) : undefined,
        };
    },

    async listFrozen(): Promise<number[]> {
        const res = await callRpc<{ appids?: unknown }>("TimefreezeListFrozen", {});
        return asArray<number>(res?.appids).filter((n) => typeof n === "number" && n > 0);
    },

    async addCustomVersion(appid: number, depotId: string, manifestId: string): Promise<GameFreezeStatus> {
        const res = await callRpc<unknown>("TimefreezeAddCustomVersion", {
            appid,
            depotId,
            manifestId,
        });
        return normalizeStatus(res);
    },

    async purgeCache(appid: number): Promise<GameFreezeStatus> {
        const res = await callRpc<unknown>("TimefreezePurgeCache", { appid });
        return normalizeStatus(res);
    },

    async logToServer(level: "info" | "warn" | "error", message: string): Promise<void> {
        try {
            await callRpc("TimefreezeLog", { level, message });
        } catch {
            /* ignore logging failure */
        }
    },
};
