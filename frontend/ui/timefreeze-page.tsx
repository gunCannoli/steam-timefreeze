import { useCallback, useEffect, useMemo, useState, type CSSProperties } from "react";
import { DialogButton, Dropdown, Field, PanelSection, Spinner, TextField } from "@steambrew/client";
import { backend, type GameFreezeStatus } from "../ports/backend";
import { fetchSteamAppInfo, runDownloadDepot, type ParsedAppInfo } from "../steam/app-info";
import { buildVersionOptions, formatUnixDate, resolveLatestTarget, type VersionOption } from "../domain/versions";
import { logger } from "../logger";

interface SteamClientPartial {
    Apps?: {
        SetAppAutoUpdateBehavior?: (appid: number, behavior: number) => void;
        JoinAppContentBeta?: (appid: number, branch: string) => void;
    };
    Console?: {
        ExecCommand?: (cmd: string) => void;
    };
    Downloads?: {
        PauseAppUpdate?: (appid: number) => void;
        RemoveFromDownloadList?: (appid: number) => void;
    };
    System?: {
        OpenInSystemBrowser?: (url: string) => void;
    };
    User?: {
        StartRestart?: (bForce?: boolean) => void;
    };
}

interface AppOverviewPartial {
    local_per_client_data?: {
        display_status?: number;
    };
}

function steamClient(): SteamClientPartial | undefined {
    return (globalThis as unknown as { SteamClient?: SteamClientPartial }).SteamClient;
}

function liveDisplayStatus(appid: number): number | undefined {
    const store = (globalThis as unknown as {
        appStore?: { GetAppOverviewByAppID?: (id: number) => AppOverviewPartial | undefined };
    }).appStore;
    return store?.GetAppOverviewByAppID?.(appid)?.local_per_client_data?.display_status;
}

const BLOCK_GAP = 22;
const BUTTON_STYLE: CSSProperties = {
    width: "auto",
    minWidth: 0,
    padding: "0 16px",
};
const RIGHT_INPUT_WRAP: CSSProperties = {
    display: "flex",
    justifyContent: "flex-end",
    width: "240px",
    maxWidth: "100%",
};
const RIGHT_INPUT_STYLE: CSSProperties = {
    width: "100%",
    textAlign: "right",
};

export function TimefreezePage({ appid }: { appid: number }) {
    const [loading, setLoading] = useState(true);
    const [busy, setBusy] = useState(false);
    const [status, setStatus] = useState<GameFreezeStatus | null>(null);
    const [appInfo, setAppInfo] = useState<ParsedAppInfo | null>(null);
    const [displayStatus, setDisplayStatus] = useState<number | undefined>(() => liveDisplayStatus(appid));
    const [selectedId, setSelectedId] = useState<string>("");
    const [message, setMessage] = useState<string>("");
    const [error, setError] = useState<string>("");

    // Historical SteamDB downgrade inputs (always visible, 2-column right-aligned)
    const [depotInput, setDepotInput] = useState("");
    const [manifestInput, setManifestInput] = useState("");

    const refresh = useCallback(async () => {
        setLoading(true);
        setError("");
        try {
            const [st, info] = await Promise.all([
                backend.getStatus(appid),
                fetchSteamAppInfo(appid),
            ]);
            if (st.error) {
                setError(st.error);
            }
            setStatus(st);
            setAppInfo(info);
            setDisplayStatus(liveDisplayStatus(appid));
            const firstDepot = Object.keys(st.installedDepots ?? {})[0];
            if (firstDepot) setDepotInput((prev) => prev || firstDepot);
        } catch (err) {
            logger.error(`refresh failed for appid=${appid}:`, err);
            setError(String(err));
        } finally {
            setLoading(false);
        }
    }, [appid]);

    useEffect(() => {
        void refresh();
    }, [refresh]);

    const options: VersionOption[] = useMemo(() => {
        if (!status) return [];
        return buildVersionOptions(status, appInfo);
    }, [status, appInfo]);

    // Default selection is always the first option (currently installed build).
    useEffect(() => {
        if (options.length === 0) return;
        const stillExists = options.some((o) => o.id === selectedId);
        if (!stillExists) {
            setSelectedId(options[0]!.id);
        }
    }, [options, selectedId]);

    const selected: VersionOption | undefined = useMemo(
        () => options.find((o) => o.id === selectedId) ?? options[0],
        [options, selectedId],
    );

    const { latestBuildId, latestDepots } = useMemo(() => {
        if (!status) return { latestBuildId: "", latestDepots: {} };
        return resolveLatestTarget(status, appInfo);
    }, [status, appInfo]);

    const handleFreeze = async () => {
        if (!status || busy) return;
        setBusy(true);
        setError("");
        setMessage("Applying Timefreeze...");
        try {
            const sc = steamClient();
            try {
                sc?.Downloads?.PauseAppUpdate?.(appid);
                sc?.Downloads?.RemoveFromDownloadList?.(appid);
                sc?.Apps?.SetAppAutoUpdateBehavior?.(appid, 1);
                sc?.Console?.ExecCommand?.(`app_update_cancel ${appid}`);
            } catch {
                /* non-fatal if SteamClient methods differ */
            }

            const res = await backend.freeze(appid, latestBuildId, latestDepots);
            setDisplayStatus(liveDisplayStatus(appid));
            if (res.error) {
                setError(res.error);
                setMessage("");
            } else {
                setStatus(res);
                const needsRestart = liveDisplayStatus(appid) === 20;
                setMessage(
                    needsRestart
                        ? `Frozen at Build ${res.installedBuildId}. Steam already cached this update in memory — click Restart Steam to switch the button to Play.`
                        : `Frozen at Build ${res.installedBuildId}. Steam will not update this game.`,
                );
            }
        } catch (err) {
            setError(String(err));
            setMessage("");
        } finally {
            setBusy(false);
        }
    };

    const handleUnfreeze = async () => {
        if (!status || busy) return;
        setBusy(true);
        setError("");
        setMessage("Removing Timefreeze...");
        try {
            const res = await backend.unfreeze(appid);
            setDisplayStatus(liveDisplayStatus(appid));
            if (res.error) {
                setError(res.error);
                setMessage("");
            } else {
                setStatus(res);
                setMessage(
                    `Unfrozen. Original Build ${res.installedBuildId} restored; Steam can update this game normally.`,
                );
            }
        } catch (err) {
            setError(String(err));
            setMessage("");
        } finally {
            setBusy(false);
        }
    };

    const handleRestartSteam = () => {
        const sc = steamClient();
        if (sc?.User?.StartRestart) {
            sc.User.StartRestart(false);
        } else {
            setMessage("Please restart Steam manually from Steam → Exit to reload the frozen manifest.");
        }
    };

    const handleSwitchBeta = async (branchName: string) => {
        if (!status || busy) return;
        setBusy(true);
        setError("");
        setMessage(`Switching to branch "${branchName}"...`);
        try {
            if (status.frozen) {
                const unf = await backend.unfreeze(appid);
                if (unf.error) {
                    setError(unf.error);
                    setMessage("");
                    return;
                }
                setStatus(unf);
            }
            const sc = steamClient();
            if (sc?.Apps?.JoinAppContentBeta) {
                sc.Apps.JoinAppContentBeta(appid, branchName);
                setMessage(
                    `Switched to branch "${branchName}". Wait for Steam to finish syncing, then click Timefreeze if you want to lock it.`,
                );
            } else {
                setError("SteamClient.Apps.JoinAppContentBeta is unavailable on this client.");
                setMessage("");
            }
        } catch (err) {
            setError(String(err));
            setMessage("");
        } finally {
            setBusy(false);
        }
    };

    const handleDownloadOption = (opt: VersionOption) => {
        const entries = Object.entries(opt.depots ?? {});
        if (entries.length === 0) {
            setError("No depot manifest IDs recorded for this version.");
            return;
        }
        setError("");
        let started = 0;
        for (const [depotId, manifestId] of entries) {
            if (runDownloadDepot(appid, depotId, manifestId)) started++;
        }
        if (started > 0) {
            setMessage(
                `Started download_depot for ${started} depot(s). Check Steam Console for progress, copy files into the game folder, then click Timefreeze.`,
            );
        } else {
            setError("Could not run download_depot via Steam Console.");
        }
    };

    const installedDepotIds = useMemo(
        () => Object.keys(status?.installedDepots ?? {}),
        [status?.installedDepots],
    );
    const knownSingleDepot = installedDepotIds.length === 1 ? installedDepotIds[0]! : null;
    const activeDepotId = knownSingleDepot ?? depotInput.trim();

    const handleManualDownload = async () => {
        const d = activeDepotId;
        const m = manifestInput.trim();
        if (!/^\d+$/.test(d) || !/^\d+$/.test(m)) {
            setError(knownSingleDepot ? "Manifest ID must be numeric." : "Depot ID and Manifest ID must be numeric.");
            return;
        }
        setBusy(true);
        setError("");
        try {
            const started = runDownloadDepot(appid, d, m);
            const updated = await backend.addCustomVersion(appid, d, m);
            if (updated.error) {
                setError(updated.error);
                return;
            }
            setStatus(updated);
            setSelectedId(`custom:${d}:${m}`);
            setManifestInput("");
            setMessage(
                started
                    ? `Added Depot ${d} · Manifest ${m} to Game Version dropdown and started download_depot (check Steam Console).`
                    : `Added Depot ${d} · Manifest ${m} to Game Version dropdown (Steam Console unavailable).`,
            );
        } catch (err) {
            setError(String(err));
        } finally {
            setBusy(false);
        }
    };

    const openSteamDb = () => {
        const url = knownSingleDepot
            ? `https://steamdb.info/depot/${knownSingleDepot}/manifests/`
            : `https://steamdb.info/app/${appid}/depots/`;
        const sc = steamClient();
        if (sc?.System?.OpenInSystemBrowser) {
            sc.System.OpenInSystemBrowser(url);
        } else {
            window.open(url, "_blank");
        }
    };

    if (loading) {
        return (
            <PanelSection title="Timefreeze">
                <Field label="Loading version info..." icon={<Spinner style={{ width: 18, height: 18 }} />} />
            </PanelSection>
        );
    }

    if (!status || !status.found) {
        return (
            <PanelSection title="Timefreeze">
                <Field
                    label="Game not installed"
                    description={
                        error ||
                        "Install this game first so Timefreeze can read and protect its Steam appmanifest."
                    }
                />
            </PanelSection>
        );
    }

    const steamStillShowsUpdate = status.frozen && displayStatus === 20;
    const updatePending =
        !status.frozen &&
        Boolean(latestBuildId) &&
        latestBuildId !== status.installedBuildId;

    const statusTitle = status.frozen
        ? steamStillShowsUpdate
            ? `Frozen at Build ${status.installedBuildId} — Restart Steam to apply`
            : `Frozen at Build ${status.installedBuildId}`
        : updatePending
          ? `Update available (Build ${status.installedBuildId} → ${latestBuildId})`
          : `Active (Build ${status.installedBuildId})`;

    const statusDesc = status.frozen
        ? steamStillShowsUpdate
            ? `Manifest is locked and spoofed to Build ${status.spoofedBuildId || latestBuildId}, but Steam had already cached the pending update before freeze. Click Restart Steam so the Play button replaces Update.`
            : `Installed ${formatUnixDate(status.installedDate ?? 0)}. Manifest is read-only and spoofed to Build ${status.spoofedBuildId || latestBuildId} so Steam will not force an update on launch.`
        : updatePending
          ? `Installed ${formatUnixDate(status.installedDate ?? 0)}. Click Timefreeze below to lock this version and stop Steam from updating.`
          : `Installed ${formatUnixDate(status.installedDate ?? 0)}. Click Timefreeze below to prevent future updates.`;

    const dropdownOptions = options.map((o) => ({ data: o.id, label: o.label }));

    // Determine primary button based on selected dropdown option & frozen state
    let primaryLabel = "Timefreeze";
    let primaryAction: () => void | Promise<void> = handleFreeze;
    let secondaryAction: { label: string; onClick: () => void } | null = null;

    if (selected?.kind === "installed") {
        if (status.frozen) {
            primaryLabel = "Unfreeze";
            primaryAction = handleUnfreeze;
            if (steamStillShowsUpdate) {
                secondaryAction = { label: "Restart Steam", onClick: handleRestartSteam };
            } else if (latestBuildId && latestBuildId !== status.spoofedBuildId) {
                secondaryAction = { label: "Re-sync Freeze", onClick: () => void handleFreeze() };
            }
        } else {
            primaryLabel = "Timefreeze";
            primaryAction = handleFreeze;
        }
    } else if (selected?.kind === "latest") {
        if (status.frozen) {
            primaryLabel = "Unfreeze & Allow Update";
            primaryAction = handleUnfreeze;
        } else {
            primaryLabel = "Already Unfrozen";
            primaryAction = handleFreeze;
        }
    } else if (selected?.kind === "beta" && selected.branchName) {
        const branch = selected.branchName;
        primaryLabel = `Switch to "${branch}"`;
        primaryAction = () => handleSwitchBeta(branch);
    } else if (selected?.kind === "history" || selected?.kind === "custom") {
        primaryLabel = "Download via Steam Console";
        primaryAction = () => handleDownloadOption(selected);
    }

    const primaryDisabled =
        busy || (selected?.kind === "latest" && !status.frozen);

    return (
        <div style={{ minWidth: 0, maxWidth: "100%", boxSizing: "border-box" }}>
            <PanelSection title="Timefreeze">
                <Field label={statusTitle} description={statusDesc} />

                <div style={{ paddingTop: BLOCK_GAP }}>
                    <Field
                        label="Game Version"
                        description="Starts on your currently installed version. Pick a version or click Timefreeze to lock this game."
                    />
                    <Field childrenContainerWidth="max">
                        <Dropdown
                            rgOptions={dropdownOptions}
                            selectedOption={selected?.id}
                            onChange={(opt) => {
                                if (typeof opt?.data === "string") setSelectedId(opt.data);
                            }}
                            disabled={busy || dropdownOptions.length === 0}
                        />
                    </Field>
                </div>

                <div style={{ paddingTop: BLOCK_GAP }}>
                    <Field
                        label={
                            busy ? (
                                <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
                                    <Spinner style={{ width: 16, height: 16 }} />
                                    {message || "Working..."}
                                </span>
                            ) : error ? (
                                <span style={{ color: "#e57373", overflowWrap: "anywhere" }}>{error}</span>
                            ) : (
                                <span
                                    style={{
                                        color: steamStillShowsUpdate
                                            ? "#e5a00d"
                                            : status.frozen
                                              ? "#8bc34a"
                                              : undefined,
                                        overflowWrap: "anywhere",
                                    }}
                                >
                                    {message ||
                                        (steamStillShowsUpdate
                                            ? "Restart Steam so the Play button replaces Update."
                                            : status.frozen
                                              ? "Protected against Steam updates."
                                              : "Ready to freeze.")}
                                </span>
                            )
                        }
                    >
                        <div style={{ display: "flex", gap: 8, justifyContent: "flex-end", flexWrap: "wrap" }}>
                            {secondaryAction && (
                                <DialogButton
                                    style={BUTTON_STYLE}
                                    disabled={busy}
                                    onClick={secondaryAction.onClick}
                                >
                                    {secondaryAction.label}
                                </DialogButton>
                            )}
                            <DialogButton
                                style={BUTTON_STYLE}
                                disabled={primaryDisabled}
                                onClick={primaryAction}
                            >
                                {busy ? "Working..." : primaryLabel}
                            </DialogButton>
                        </div>
                    </Field>
                </div>

                <div style={{ paddingTop: BLOCK_GAP }}>
                    {/* Row 1: label (left) / Open SteamDB button (right) */}
                    <Field label="Historical Downgrade (SteamDB)">
                        <div style={{ display: "flex", justifyContent: "flex-end" }}>
                            <DialogButton style={BUTTON_STYLE} onClick={openSteamDb}>
                                Open SteamDB
                            </DialogButton>
                        </div>
                    </Field>

                    {/* Row 2: description */}
                    <Field
                        description={
                            knownSingleDepot
                                ? `Steam's API only lists installed, latest, and beta builds. Look up an older Manifest ID for Depot ${knownSingleDepot} on SteamDB, then download it to add it to the Game Version dropdown.`
                                : "Steam's API only lists installed, latest, and beta builds. Look up an older Depot ID and Manifest ID on SteamDB, then download it to add it as a selectable option in the Game Version dropdown."
                        }
                    />

                    {/* Row 3: Depot ID (only shown when the game has multiple or unknown depots) */}
                    {!knownSingleDepot && (
                        <Field label="Depot ID">
                            <div style={RIGHT_INPUT_WRAP}>
                                <TextField
                                    value={depotInput}
                                    onChange={(e) => setDepotInput(e.target.value)}
                                    style={RIGHT_INPUT_STYLE}
                                />
                            </div>
                        </Field>
                    )}

                    {/* Row 4: Manifest ID (left) / right-aligned input (right) */}
                    <Field
                        label="Manifest ID"
                        description={knownSingleDepot ? `Depot ${knownSingleDepot}` : undefined}
                    >
                        <div style={RIGHT_INPUT_WRAP}>
                            <TextField
                                value={manifestInput}
                                onChange={(e) => setManifestInput(e.target.value)}
                                style={RIGHT_INPUT_STYLE}
                            />
                        </div>
                    </Field>

                    {/* Row 5: label (left) / Download button (right) */}
                    <Field
                        label="Download Depot"
                        description="Runs Steam's download_depot command and adds this depot to the Game Version dropdown."
                    >
                        <div style={{ display: "flex", justifyContent: "flex-end" }}>
                            <DialogButton
                                style={BUTTON_STYLE}
                                disabled={busy || !activeDepotId || !manifestInput.trim()}
                                onClick={() => void handleManualDownload()}
                            >
                                Download
                            </DialogButton>
                        </div>
                    </Field>
                </div>
            </PanelSection>
        </div>
    );
}
