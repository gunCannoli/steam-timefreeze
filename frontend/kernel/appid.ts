/**
 * Steam's CEF runtime hands out shortcut appids (> 0x7FFFFFFF) as signed 32-bit integers.
 * Normalise every appid to an unsigned 32-bit integer (knowledgebase.md § The two identifiers).
 */
export const NON_STEAM_APP_MASK = 0x80000000;

export function normalizeAppId(raw: number): number | undefined {
    if (!Number.isFinite(raw)) return undefined;
    const u = raw >>> 0;
    return u > 0 ? u : undefined;
}

export function isNativeSteamAppId(raw: number): boolean {
    const u = normalizeAppId(raw);
    return u !== undefined && u < NON_STEAM_APP_MASK;
}
