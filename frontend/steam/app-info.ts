/**
 * Reads live Steam PICS app info (branches, buildids, timestamps, depot manifest GIDs)
 * directly from the running Steam client via SteamClient.Console (`app_info_print <appid>`).
 *
 * Pure parser is exported so Node unit tests can verify it against real Steam output.
 */

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

// Serialise console queries so concurrent calls never interleave spew output.
let queue: Promise<unknown> = Promise.resolve();

interface ConsoleClient {
    ExecCommand?: (cmd: string) => void;
    RegisterForSpewOutput?: (cb: (spew: { spew?: string }) => void) => { unregister?: () => void };
}

/**
 * Query the running Steam client for live PICS info (`app_info_print <appid>`).
 */
export function fetchSteamAppInfo(appid: number, timeoutMs = 900): Promise<ParsedAppInfo> {
    const task = async (): Promise<ParsedAppInfo> => {
        const consoleApi = (globalThis as unknown as { SteamClient?: { Console?: ConsoleClient } }).SteamClient?.Console;
        if (!consoleApi?.ExecCommand || !consoleApi?.RegisterForSpewOutput) {
            return { appid, branches: [], branchDepots: {} };
        }

        return new Promise<ParsedAppInfo>((resolve) => {
            const chunks: string[] = [];
            let settled = false;
            const sub = consoleApi.RegisterForSpewOutput!((ev) => {
                if (ev && typeof ev.spew === "string") chunks.push(ev.spew);
            });

            const finish = () => {
                if (settled) return;
                settled = true;
                try {
                    sub?.unregister?.();
                } catch {
                    /* ignore */
                }
                resolve(parseAppInfoText(appid, chunks.join("")));
            };

            try {
                consoleApi.ExecCommand!(`app_info_print ${appid}`);
            } catch {
                finish();
                return;
            }

            setTimeout(finish, timeoutMs);
        });
    };

    const next = queue.then(task, task);
    queue = next.catch(() => undefined);
    return next;
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
