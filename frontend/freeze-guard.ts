/**
 * Keeps frozen games frozen while Steam runs, and leaves a full trail in timefreeze.log whenever
 * Steam still wants to update one.
 *
 * - Startup sync: re-spoofs every frozen game to the latest build (game + DLC app info).
 * - Watcher: every WATCH_MS, a frozen game whose display status turns to an update state
 *   (UpdateRequired / Queued / Downloading ...) is logged, diagnosed (manifest, depots, Steam's own
 *   content_log reason) and, at most once per REASSERT_MS, paused and re-frozen. On Linux a read-only
 *   manifest does not stop Steam (it replaces the file by rename), so this re-assert is the fallback.
 */
import { backend } from "./ports/backend";
import { fetchAppInfoForInstall } from "./steam/app-info";
import { resolveLatestTarget } from "./domain/versions";
import { displayStatusName, isUpdateState, liveDisplayStatus } from "./steam/display-status";
import { logger } from "./logger";

const WATCH_MS = 15000;
const REASSERT_MS = 5 * 60 * 1000;

const lastSeen = new Map<number, number | undefined>();
const lastReassert = new Map<number, number>();
let timer: ReturnType<typeof setInterval> | null = null;
let ticking = false;

interface DownloadsPartial {
    PauseAppUpdate?: (appid: number) => void;
    RemoveFromDownloadList?: (appid: number) => void;
}

function stopSteamUpdate(appid: number): void {
    const dl = (globalThis as unknown as { SteamClient?: { Downloads?: DownloadsPartial } }).SteamClient?.Downloads;
    try {
        dl?.PauseAppUpdate?.(appid);
        dl?.RemoveFromDownloadList?.(appid);
    } catch {
        /* methods differ between Steam builds */
    }
}

/** Resolve targets (with DLC depots), diagnose, and re-freeze one game. */
export async function reassertFreeze(appid: number, reason: string, force = false): Promise<void> {
    const ds = liveDisplayStatus(appid);
    const status = await backend.getStatus(appid);
    if (!status.found || !status.frozen) return;
    const info = await fetchAppInfoForInstall(appid, status.installedDepots, status.installedDepotDlc);
    const { latestBuildId, latestDepots } = resolveLatestTarget(status, info);
    const diag = await backend.diagnose(appid, reason, { displayStatus: ds, latestBuildId, latestDepots });

    const now = Date.now();
    const last = lastReassert.get(appid) ?? 0;
    if (!force && now - last < REASSERT_MS) {
        logger.info(`[guard] appid=${appid} re-freeze skipped (last ${Math.round((now - last) / 1000)}s ago)`);
        return;
    }
    lastReassert.set(appid, now);
    if (isUpdateState(ds)) stopSteamUpdate(appid);
    const res = await backend.freeze(appid, latestBuildId, latestDepots);
    const after = liveDisplayStatus(appid);
    logger.info(
        `[guard] appid=${appid} reason=${reason} re-frozen err=${res.error ?? "none"} spoof=${res.spoofedBuildId ?? ""} ` +
        `display=${displayStatusName(ds)}->${displayStatusName(after)} stale=[${diag.staleDepots.join(",")}] ` +
        `steamWanted=[${diag.steamUpdatedDepots.join(",")}]`,
    );
}

async function tick(): Promise<void> {
    if (ticking) return;
    ticking = true;
    try {
        const appids = await backend.listFrozen();
        for (const appid of appids) {
            const ds = liveDisplayStatus(appid);
            const had = lastSeen.has(appid);
            const prev = lastSeen.get(appid);
            lastSeen.set(appid, ds);
            if (had && ds === prev) continue;
            if (isUpdateState(ds)) {
                logger.warn(`[watch] frozen appid=${appid} display ${displayStatusName(prev)}->${displayStatusName(ds)}: Steam wants to update it`);
                try {
                    await reassertFreeze(appid, `watch-${displayStatusName(ds)}`);
                } catch (err) {
                    logger.warn(`[watch] re-freeze failed for appid=${appid}:`, String(err));
                }
            } else if (had) {
                logger.info(`[watch] frozen appid=${appid} display ${displayStatusName(prev)}->${displayStatusName(ds)}`);
            }
        }
    } catch (err) {
        logger.warn("[watch] tick failed:", String(err));
    } finally {
        ticking = false;
    }
}

export async function syncAllFrozenOnStartup(): Promise<void> {
    try {
        const appids = await backend.listFrozen();
        logger.info(`[startup] ${appids.length} frozen game(s): [${appids.join(",")}]`);
        for (const appid of appids) {
            try {
                const ds = liveDisplayStatus(appid);
                lastSeen.set(appid, ds);
                const status = await backend.getStatus(appid);
                if (!status.found || !status.frozen) continue;
                const info = await fetchAppInfoForInstall(appid, status.installedDepots, status.installedDepotDlc);
                const { latestBuildId, latestDepots } = resolveLatestTarget(status, info);
                const res = await backend.syncFrozen(appid, latestBuildId, latestDepots);
                logger.info(
                    `[startup] appid=${appid} display=${displayStatusName(ds)} sync=${res.synced ? "re-spoofed" : res.reason ?? res.error ?? "?"} ` +
                    `latest=${latestBuildId} depots=${Object.keys(latestDepots).length}`,
                );
                if (isUpdateState(ds)) {
                    // Steam read the manifest before this sync ran, or something else still flags the game.
                    await reassertFreeze(appid, `startup-${displayStatusName(ds)}`, true);
                }
            } catch (err) {
                logger.warn(`Startup sync failed for appid=${appid}:`, String(err));
            }
        }
    } catch (err) {
        logger.warn("Startup sync listFrozen failed:", String(err));
    }
}

export function startFreezeGuard(): void {
    if (timer) return;
    timer = setInterval(() => void tick(), WATCH_MS);
}
