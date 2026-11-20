/**
 * Pure domain logic for building the Timefreeze version dropdown options.
 * No Steam globals or React imports — unit-tested directly in Node.
 */
import type { GameFreezeStatus } from "../ports/backend.ts";
import type { ParsedAppInfo } from "../steam/app-info.ts";

export type VersionKind = "installed" | "latest" | "beta" | "history" | "custom";

export interface VersionOption {
    /** Stable key used as Dropdown value. */
    id: string;
    kind: VersionKind;
    buildid: string;
    date: number;
    branchName?: string;
    depots?: Record<string, string>;
    label: string;
}

/** Guardrail 21: Lua encodes empty tables as `{}` (object), never `[]`. */
export function asArray<T>(val: unknown): T[] {
    return Array.isArray(val) ? (val as T[]) : [];
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function formatUnixDate(unixSec: number): string {
    if (!Number.isFinite(unixSec) || unixSec <= 0) return "Unknown date";
    const d = new Date(unixSec * 1000);
    const mon = MONTHS[d.getUTCMonth()] ?? "Jan";
    const day = d.getUTCDate();
    const year = d.getUTCFullYear();
    return `${mon} ${day}, ${year}`;
}

/**
 * Build the ordered list of version options for the dropdown.
 * The currently installed version is ALWAYS first (and selected by default)
 * so the user can open Properties -> Timefreeze and hit Timefreeze in one click.
 */
export function buildVersionOptions(
    status: Pick<GameFreezeStatus, "found" | "frozen" | "installedBuildId" | "installedDate" | "installedDepots" | "targetBuildId" | "history" | "betakey"> & {
        customVersions?: GameFreezeStatus["customVersions"];
    },
    appInfo: ParsedAppInfo | null,
): VersionOption[] {
    if (!status.found) return [];

    const options: VersionOption[] = [];
    const seenBuilds = new Set<string>();

    const installedBuild = status.installedBuildId ?? "";
    const installedDate = status.installedDate ?? 0;

    // 1. Currently installed version (ALWAYS first, default selected)
    if (installedBuild) {
        seenBuilds.add(installedBuild);
        const tag = status.frozen ? "Installed · Frozen" : "Installed";
        options.push({
            id: `installed:${installedBuild}`,
            kind: "installed",
            buildid: installedBuild,
            date: installedDate,
            branchName: status.betakey || "public",
            depots: status.installedDepots,
            label: `Build ${installedBuild} — ${formatUnixDate(installedDate)} (${tag})`,
        });
    }

    // 2. Latest public branch (if different from installed)
    const publicBranch = appInfo?.branches.find((b) => b.name === "public");
    const latestBuild = publicBranch?.buildid || (status.targetBuildId && status.targetBuildId !== "0" ? status.targetBuildId : "");
    const latestDate = publicBranch?.timeupdated ?? 0;

    if (latestBuild && !seenBuilds.has(latestBuild)) {
        seenBuilds.add(latestBuild);
        const suffix = status.frozen ? "Latest — Unfreeze to update" : "Latest available";
        options.push({
            id: `latest:${latestBuild}`,
            kind: "latest",
            buildid: latestBuild,
            date: latestDate,
            branchName: "public",
            depots: appInfo?.branchDepots?.["public"],
            label: `Build ${latestBuild} — ${formatUnixDate(latestDate)} (${suffix})`,
        });
    }

    // 3. Public Steam beta branches (excluding public and password-protected branches)
    if (appInfo) {
        for (const b of appInfo.branches) {
            if (b.name === "public" || b.pwdrequired) continue;
            const desc = b.description ? ` · ${b.description}` : "";
            options.push({
                id: `beta:${b.name}:${b.buildid}`,
                kind: "beta",
                buildid: b.buildid,
                date: b.timeupdated,
                branchName: b.name,
                depots: appInfo.branchDepots[b.name],
                label: `Build ${b.buildid} — ${formatUnixDate(b.timeupdated)} (Beta: ${b.name}${desc})`,
            });
            seenBuilds.add(b.buildid);
        }
    }

    // 4. Locally recorded historical builds (previously seen on this machine)
    const history = Array.isArray(status.history) ? [...status.history] : [];
    history.sort((a, b) => (b.date || 0) - (a.date || 0));
    for (const h of history) {
        if (!h.buildid || seenBuilds.has(h.buildid)) continue;
        seenBuilds.add(h.buildid);
        options.push({
            id: `history:${h.buildid}`,
            kind: "history",
            buildid: h.buildid,
            date: h.date,
            depots: h.depots,
            label: `Build ${h.buildid} — ${formatUnixDate(h.date)} (Previously installed)`,
        });
    }

    // 5. Custom SteamDB depot+manifest entries downloaded by the user
    const custom = Array.isArray(status.customVersions) ? [...status.customVersions] : [];
    custom.sort((a, b) => (b.addedAt || 0) - (a.addedAt || 0));
    for (const c of custom) {
        if (!c.depotId || !c.manifestId) continue;
        const dateStr = c.addedAt ? ` — ${formatUnixDate(c.addedAt)}` : "";
        options.push({
            id: `custom:${c.depotId}:${c.manifestId}`,
            kind: "custom",
            buildid: c.manifestId,
            date: c.addedAt ?? 0,
            depots: { [c.depotId]: c.manifestId },
            label: `Depot ${c.depotId} · Manifest ${c.manifestId}${dateStr} (SteamDB)`,
        });
    }

    return options;
}

/**
 * Determine the latest public buildid and depot manifest GIDs to spoof into appmanifest.
 */
export function resolveLatestTarget(
    status: Pick<GameFreezeStatus, "targetBuildId" | "installedBuildId" | "betakey">,
    appInfo: ParsedAppInfo | null,
): { latestBuildId: string; latestDepots: Record<string, string> } {
    const activeBranch = status.betakey && status.betakey !== "" ? status.betakey : "public";
    const branch = appInfo?.branches.find((b) => b.name === activeBranch)
        ?? appInfo?.branches.find((b) => b.name === "public");

    const latestBuildId = branch?.buildid
        || (status.targetBuildId && status.targetBuildId !== "0" ? status.targetBuildId : "")
        || status.installedBuildId
        || "";

    const latestDepots = (branch && appInfo?.branchDepots[branch.name])
        || appInfo?.branchDepots?.["public"]
        || {};

    return { latestBuildId, latestDepots };
}
