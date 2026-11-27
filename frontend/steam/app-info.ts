/**
 * Reads live Steam PICS app info (branches, buildids, timestamps, depot manifest GIDs).
 *
 * Multi-source resolution:
 * 1. SteamClient.Console (`app_info_print <appid>`) if developer console is active.
 * 2. Fallback: SteamCMD Web API (`https://api.steamcmd.net/v1/info/<appid>`) with fast timeout
 *    and in-memory caching (so users without -console flag still get accurate spoof buildids!).
 *
 * Pure parsers are exported so Node unit tests can verify them against real Steam/API output.
 */

import { logger } from "../logger.ts";

export interface BranchInfo {
    name: string;
    buildid: string;
    timeupdated: number;
    description: string;
    pwdrequired: boolean;
}

export interface ParsedAppInfo {
    appid: number;
    branches: BranchInfo[];
    /** Per-branch map of depotId -> manifest gid. */
    branchDepots: Record<string, Record<string, string>>;
}

/**
 * Parse the `"depots"` block from `app_info_print <appid>` text.
 * Pure function (no Steam globals), unit-tested in Node.
 */
export function parseAppInfoText(appid: number, text: string): ParsedAppInfo {
    const result: ParsedAppInfo = {
        appid,
        branches: [],
        branchDepots: {},
    };
    if (!text) return result;

    const depotsIdx = text.indexOf('"depots"');
    if (depotsIdx < 0) return result;
    const slice = text.slice(depotsIdx);

    // Tokenise quotes and braces inside the "depots" block
    const tokens: Array<{ type: "brace" | "str"; value: string }> = [];
    let i = 0;
    const len = slice.length;
    let started = false;
    let depth = 0;

    while (i < len) {
        const ch = slice[i]!;
        if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
            i++;
            continue;
        }
        if (ch === "{") {
            started = true;
            depth++;
            tokens.push({ type: "brace", value: "{" });
            i++;
            continue;
        }
        if (ch === "}") {
            depth--;
            tokens.push({ type: "brace", value: "}" });
            i++;
            if (started && depth <= 0) break;
            continue;
        }
        if (ch === '"') {
            i++;
            let out = "";
            while (i < len) {
                const c = slice[i]!;
                if (c === "\\" && i + 1 < len) {
                    out += slice[i + 1]!;
                    i += 2;
                } else if (c === '"') {
                    i++;
                    break;
                } else {
                    out += c;
                    i++;
                }
            }
            tokens.push({ type: "str", value: out });
            continue;
        }
        i++;
    }

    let pos = 0;
    const parseObj = (): Record<string, unknown> => {
        const obj: Record<string, unknown> = {};
        while (pos < tokens.length) {
            const t = tokens[pos]!;
            if (t.type === "brace" && t.value === "}") {
                pos++;
                break;
            }
            if (t.type !== "str") {
                pos++;
                continue;
            }
            const key = t.value;
            pos++;
            const next = tokens[pos];
            if (!next) break;
            if (next.type === "brace" && next.value === "{") {
                pos++;
                obj[key] = parseObj();
            } else if (next.type === "str") {
                pos++;
                obj[key] = next.value;
            }
        }
        return obj;
    };

    // Expect: "depots" { ... }
    if (tokens[0]?.value === "depots" && tokens[1]?.value === "{") {
        pos = 2;
    } else {
        return result;
    }
    const depots = parseObj();

    // Extract branches
    const branchesObj = depots["branches"];
    if (branchesObj && typeof branchesObj === "object") {
        for (const [name, raw] of Object.entries(branchesObj as Record<string, unknown>)) {
            if (!raw || typeof raw !== "object") continue;
            const b = raw as Record<string, unknown>;
            const buildid = typeof b["buildid"] === "string" ? b["buildid"] : "";
            if (!buildid) continue;
            const timeupdated = Number(b["timeupdated"] ?? b["timebuildupdated"] ?? 0) || 0;
            const description = typeof b["description"] === "string" ? b["description"] : "";
            const pwdrequired = String(b["pwdrequired"] ?? "0") === "1";
            result.branches.push({ name, buildid, timeupdated, description, pwdrequired });
        }
    }

    // Sort: public first, then newest timeupdated descending
    result.branches.sort((a, b) => {
        if (a.name === "public") return -1;
        if (b.name === "public") return 1;
        return b.timeupdated - a.timeupdated;
    });

    // Extract depot manifests per branch
    for (const [depotKey, rawDepot] of Object.entries(depots)) {
        if (!/^\d+$/.test(depotKey) || !rawDepot || typeof rawDepot !== "object") continue;
        const manifests = (rawDepot as Record<string, unknown>)["manifests"];
        if (!manifests || typeof manifests !== "object") continue;
        for (const [branchName, mVal] of Object.entries(manifests as Record<string, unknown>)) {
            let gid = "";
            if (typeof mVal === "string") {
                gid = mVal;
            } else if (mVal && typeof mVal === "object") {
                const g = (mVal as Record<string, unknown>)["gid"];
                if (typeof g === "string") gid = g;
            }
            if (gid) {
                if (!result.branchDepots[branchName]) result.branchDepots[branchName] = {};
                result.branchDepots[branchName]![depotKey] = gid;
            }
        }
    }

    return result;
}

/**
 * Parse the API response from https://api.steamcmd.net/v1/info/<appid>.
 * Pure function, unit-tested in Node.
 */
export function parseSteamCmdApiData(appid: number, data: unknown): ParsedAppInfo {
    const result: ParsedAppInfo = { appid, branches: [], branchDepots: {} };
    if (!data || typeof data !== "object") return result;

    const root = (data as Record<string, unknown>)[String(appid)] as Record<string, unknown> | undefined;
    if (!root || typeof root !== "object") return result;

    const depots = root["depots"] as Record<string, unknown> | undefined;
    if (!depots || typeof depots !== "object") return result;

    const branchesObj = depots["branches"] as Record<string, unknown> | undefined;
    if (branchesObj && typeof branchesObj === "object") {
        for (const [name, raw] of Object.entries(branchesObj)) {
            if (!raw || typeof raw !== "object") continue;
            const b = raw as Record<string, unknown>;
            const buildid = typeof b["buildid"] === "string" ? b["buildid"] : "";
            if (!buildid) continue;
            const timeupdated = Number(b["timeupdated"] ?? b["timebuildupdated"] ?? 0) || 0;
            const description = typeof b["description"] === "string" ? b["description"] : "";
            const pwdrequired = String(b["pwdrequired"] ?? "0") === "1";
            result.branches.push({ name, buildid, timeupdated, description, pwdrequired });
        }
    }

    result.branches.sort((a, b) => {
        if (a.name === "public") return -1;
        if (b.name === "public") return 1;
        return b.timeupdated - a.timeupdated;
    });

    for (const [depotKey, rawDepot] of Object.entries(depots)) {
        if (!/^\d+$/.test(depotKey) || !rawDepot || typeof rawDepot !== "object") continue;
        const manifests = (rawDepot as Record<string, unknown>)["manifests"] as Record<string, unknown> | undefined;
        if (!manifests || typeof manifests !== "object") continue;
        for (const [branchName, mVal] of Object.entries(manifests)) {
            let gid = "";
            if (typeof mVal === "string") {
                gid = mVal;
            } else if (mVal && typeof mVal === "object") {
                const g = (mVal as Record<string, unknown>)["gid"];
                if (typeof g === "string") gid = g;
            }
            if (gid) {
                if (!result.branchDepots[branchName]) result.branchDepots[branchName] = {};
                result.branchDepots[branchName]![depotKey] = gid;
            }
        }
    }

    return result;
}

// In-memory cache to avoid duplicate API requests (1 hour TTL)
const cache = new Map<number, { info: ParsedAppInfo; expires: number }>();

// Serialise console queries so concurrent calls never interleave spew output.
let queue: Promise<unknown> = Promise.resolve();

interface ConsoleClient {
    ExecCommand?: (cmd: string) => void;
    RegisterForSpewOutput?: (cb: (spew: { spew?: string }) => void) => { unregister?: () => void };
}

let consoleMissingLogged = false;

async function queryConsole(appid: number, timeoutMs: number): Promise<ParsedAppInfo | null> {
    const consoleApi = (globalThis as unknown as { SteamClient?: { Console?: ConsoleClient } }).SteamClient?.Console;
    if (!consoleApi?.ExecCommand || !consoleApi?.RegisterForSpewOutput) {
        if (!consoleMissingLogged) {
            consoleMissingLogged = true;
            logger.warn("SteamClient.Console unavailable: app info comes from the Web API only");
        }
        return null;
    }

    return new Promise<ParsedAppInfo>((resolve) => {
        const chunks: string[] = [];
        let settled = false;
        let settleTimer: ReturnType<typeof setTimeout> | null = null;
        let maxTimer: ReturnType<typeof setTimeout> | null = null;

        const finish = () => {
            if (settled) return;
            settled = true;
            if (settleTimer) clearTimeout(settleTimer);
            if (maxTimer) clearTimeout(maxTimer);
            try {
                sub?.unregister?.();
            } catch {
                /* ignore */
            }
            resolve(parseAppInfoText(appid, chunks.join("")));
        };

        const sub = consoleApi.RegisterForSpewOutput!((ev) => {
            if (ev && typeof ev.spew === "string") {
                chunks.push(ev.spew);
                if (settleTimer) clearTimeout(settleTimer);
                settleTimer = setTimeout(finish, 250);
            }
        });

        try {
            consoleApi.ExecCommand!(`app_info_print ${appid}`);
        } catch {
            finish();
            return;
        }

        maxTimer = setTimeout(finish, Math.max(timeoutMs, 2000));
    });
}

async function queryWebFallback(appid: number, timeoutMs = 2500): Promise<ParsedAppInfo | null> {
    if (typeof fetch !== "function") return null;
    try {
        const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
        const timer = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
        const res = await fetch(`https://api.steamcmd.net/v1/info/${appid}`, {
            headers: { "User-Agent": "steam-timefreeze" },
            signal: controller?.signal,
        });
        if (timer) clearTimeout(timer);
        if (!res.ok) {
            logger.warn(`Web API fallback HTTP ${res.status} for appid=${appid}`);
            return null;
        }
        const json = await res.json() as { data?: unknown };
        if (json && json.data) {
            const parsed = parseSteamCmdApiData(appid, json.data);
            // A DLC's app info often has depots and no branches block: its public manifests still count.
            if (parsed.branches.length > 0 || Object.keys(parsed.branchDepots["public"] ?? {}).length > 0) {
                return parsed;
            }
        }
    } catch (err) {
        logger.warn(`Web API fallback failed for appid=${appid} (offline or unreachable):`, err);
    }
    return null;
}

/**
 * Query live PICS info via Steam Client console (if available) with automatic
 * Web API fallback (so users without Steam developer flags still get latest build/depot targets).
 */
export function fetchSteamAppInfo(appid: number, timeoutMs = 900): Promise<ParsedAppInfo> {
    const cached = cache.get(appid);
    if (cached && Date.now() < cached.expires) {
        return Promise.resolve(cached.info);
    }

    const task = async (): Promise<ParsedAppInfo> => {
        // 1. Try SteamClient console first
        const fromConsole = await queryConsole(appid, timeoutMs);
        const consolePublicDepots = Object.keys(fromConsole?.branchDepots?.["public"] ?? {}).length;
        if (fromConsole && consolePublicDepots > 0) {
            cache.set(appid, { info: fromConsole, expires: Date.now() + 3600000 });
            logger.info(`Resolved appInfo for appid=${appid} via SteamClient.Console (${fromConsole.branches.length} branch(es), ${consolePublicDepots} public depot(s))`);
            return fromConsole;
        }

        // 2. Try Web API fallback (also used if console returned branches without depot GIDs)
        const fromWeb = await queryWebFallback(appid);
        if (fromWeb && (fromWeb.branches.length > 0 || Object.keys(fromWeb.branchDepots["public"] ?? {}).length > 0)) {
            cache.set(appid, { info: fromWeb, expires: Date.now() + 3600000 });
            const webPublicDepots = Object.keys(fromWeb.branchDepots["public"] ?? {}).length;
            logger.info(`Resolved appInfo for appid=${appid} via SteamCMD Web API fallback (${fromWeb.branches.length} branch(es), ${webPublicDepots} public depot(s))`);
            return fromWeb;
        }

        if (fromConsole && fromConsole.branches.length > 0) {
            cache.set(appid, { info: fromConsole, expires: Date.now() + 3600000 });
            logger.warn(`Resolved appInfo for appid=${appid} via SteamClient.Console with 0 public depots (${fromConsole.branches.length} branch(es))`);
            return fromConsole;
        }

        logger.warn(`Failed to resolve appInfo for appid=${appid} from both Console and Web API`);
        return { appid, branches: [], branchDepots: {} };
    };

    const next = queue.then(task, task);
    queue = next.catch(() => undefined);
    return next;
}

/**
 * Installed depots that the game's own app info names no manifest for, grouped by the DLC that owns
 * them. Games with `hasdepotsindlc` (Cyberpunk 2077's Phantom Liberty, 2138330) keep DLC depots only in
 * the DLC's app info, so `app_info_print <game>` never lists their latest manifest. Pure.
 */
export function unresolvedDlcDepots(
    parent: ParsedAppInfo,
    installedDepotIds: string[],
    depotDlc: Record<string, string>,
): { byDlc: Record<string, string[]>; orphans: string[] } {
    const known = new Set<string>();
    for (const map of Object.values(parent.branchDepots)) {
        for (const d of Object.keys(map)) known.add(d);
    }
    const byDlc: Record<string, string[]> = {};
    const orphans: string[] = [];
    for (const d of installedDepotIds) {
        if (known.has(d)) continue;
        const dlc = depotDlc[d];
        if (dlc && dlc !== String(parent.appid)) {
            (byDlc[dlc] ??= []).push(d);
        } else {
            orphans.push(d);
        }
    }
    return { byDlc, orphans };
}

/**
 * Merge DLC app infos' per-branch depot manifests into the game's (never overriding the game's own
 * entries). A DLC branch missing from the game keeps its name, so `public` always merges. Pure.
 */
export function mergeDlcAppInfo(parent: ParsedAppInfo, dlcInfos: ParsedAppInfo[]): ParsedAppInfo {
    const branchDepots: Record<string, Record<string, string>> = {};
    for (const [b, map] of Object.entries(parent.branchDepots)) branchDepots[b] = { ...map };
    for (const dlc of dlcInfos) {
        for (const [b, map] of Object.entries(dlc.branchDepots)) {
            const target = (branchDepots[b] ??= {});
            for (const [d, gid] of Object.entries(map)) {
                if (!target[d]) target[d] = gid;
            }
        }
    }
    return { appid: parent.appid, branches: parent.branches, branchDepots };
}

/**
 * The game's app info plus the app info of every DLC that owns an installed depot the game's own info
 * leaves out, so the freeze can spoof every installed depot (a stale DLC depot keeps Steam's Update button).
 */
export async function fetchAppInfoForInstall(
    appid: number,
    installedDepots: Record<string, string> | undefined,
    depotDlc: Record<string, string> | undefined,
): Promise<ParsedAppInfo> {
    const parent = await fetchSteamAppInfo(appid);
    const ids = Object.keys(installedDepots ?? {});
    if (ids.length === 0 || parent.branches.length === 0) return parent;
    const { byDlc, orphans } = unresolvedDlcDepots(parent, ids, depotDlc ?? {});
    const dlcIds = Object.keys(byDlc);
    if (dlcIds.length === 0) {
        if (orphans.length > 0) {
            logger.warn(`appid=${appid}: ${orphans.length} installed depot(s) not in app info and not tagged as DLC: [${orphans.join(",")}]`);
        }
        return parent;
    }
    const dlcInfos: ParsedAppInfo[] = [];
    for (const dlc of dlcIds) {
        const n = Number(dlc);
        if (!Number.isFinite(n) || n <= 0) continue;
        dlcInfos.push(await fetchSteamAppInfo(n));
    }
    const merged = mergeDlcAppInfo(parent, dlcInfos);
    const still = unresolvedDlcDepots(merged, ids, depotDlc ?? {});
    const stillIds = [...Object.values(still.byDlc).flat(), ...still.orphans];
    logger.info(
        `appid=${appid}: merged DLC app info [${dlcIds.join(",")}] for depot(s) [${Object.values(byDlc).flat().join(",")}]; ` +
        (stillIds.length > 0 ? `still unresolved [${stillIds.join(",")}]` : "all installed depots resolved"),
    );
    return merged;
}

/**
 * Trigger Steam's built-in `download_depot` command via the client console.
 */
export function runDownloadDepot(appid: number, depotId: string, manifestId: string): boolean {
    const consoleApi = (globalThis as unknown as { SteamClient?: { Console?: ConsoleClient } }).SteamClient?.Console;
    if (!consoleApi?.ExecCommand) return false;
    if (!/^\d+$/.test(depotId) || !/^\d+$/.test(manifestId)) return false;
    consoleApi.ExecCommand(`download_depot ${appid} ${depotId} ${manifestId}`);
    return true;
}
