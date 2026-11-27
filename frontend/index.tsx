/**
 * steam-timefreeze (Timefreeze) — composition root.
 *
 * No Millennium settings panel: adds a "Timefreeze" tab directly to every
 * native Steam game's Properties dialog, keeps frozen games in sync on startup
 * whenever Steam pushes a newer public build, and watches them while Steam runs.
 */
import { installPropertiesSurface, propertiesDiagnostics } from "./surfaces/properties";
import { TimefreezePage } from "./ui/timefreeze-page";
import { backend } from "./ports/backend";
import { startFreezeGuard, syncAllFrozenOnStartup } from "./freeze-guard";
import { logger, setLogListener } from "./logger";

// Pipe frontend logs to backend root log file
setLogListener((level, message) => {
    void backend.logToServer(level, message);
});

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
        void syncAllFrozenOnStartup().finally(() => startFreezeGuard());
    }, 4000);
}
