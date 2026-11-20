/**
 * steam-timefreeze (Timefreeze) — composition root.
 *
 * No Millennium settings panel: adds a "Timefreeze" tab directly to every
 * native Steam game's Properties dialog, and keeps frozen games in sync on startup
 * whenever Steam pushes a newer public build.
 */
import { installPropertiesSurface, propertiesDiagnostics } from "./surfaces/properties";
import { TimefreezePage } from "./ui/timefreeze-page";
import { backend } from "./ports/backend";
import { fetchSteamAppInfo } from "./steam/app-info";
import { resolveLatestTarget } from "./domain/versions";
import { logger } from "./logger";

async function syncAllFrozenOnStartup(): Promise<void> {
    try {
        const appids = await backend.listFrozen();
        if (appids.length === 0) return;
        logger.info(`Checking ${appids.length} frozen game(s) on startup...`);
        for (const appid of appids) {
            try {
                const [status, info] = await Promise.all([
                    backend.getStatus(appid),
                    fetchSteamAppInfo(appid),
                ]);
                if (!status.found || !status.frozen) continue;
                const { latestBuildId, latestDepots } = resolveLatestTarget(status, info);
                const res = await backend.syncFrozen(appid, latestBuildId, latestDepots);
                if (res.synced) {
                    logger.info(`Auto-synced frozen appid=${appid} to latest spoof build ${latestBuildId}`);
                }
            } catch (err) {
                logger.warn(`Startup sync failed for appid=${appid}:`, err);
            }
        }
    } catch (err) {
        logger.warn("Startup sync listFrozen failed:", err);
    }
}

/** Exposed on PLUGIN_LIST for live CDP checks. */
export const diagnostics = () => ({
    properties: propertiesDiagnostics(),
});

export default async function OnPluginLoaded(): Promise<void> {
    installPropertiesSurface({
        body: TimefreezePage,
        log: (msg) => logger.warn(msg),
    });
    logger.info("Ready. Timefreeze tab added to Steam game Properties dialogs.");

    // Delay startup sync slightly so Steam's console & PICS cache are initialized.
    setTimeout(() => {
        void syncAllFrozenOnStartup();
    }, 6000);
}
