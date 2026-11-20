/**
 * Surface `properties`, pure part: recognising a native Steam game's Properties dialog page list
 * (no Steam globals, no React — unit-tested directly in Node).
 */
import { isNativeSteamAppId, normalizeAppId } from "../../kernel/appid.ts";

export const ROUTE_PREFIX = "/app/:appid/properties/";
export const GENERAL_ROUTE = `${ROUTE_PREFIX}general`;
export const TIMEFREEZE_ROUTE = `${ROUTE_PREFIX}timefreeze`;
/** Steam's own list has at most ~15 entries; a longer array is something else. */
export const MAX_PAGES = 25;

export interface PageEntry {
    title: string;
    route: string;
    link: string;
    content: unknown;
}

/**
 * Return the native game Properties dialog's `pages` array from `props`, or undefined.
 * O(1) per call (guardrail 2: runs for every element in the client).
 * Only matches native Steam games (first page is `/app/:appid/properties/general`),
 * leaving non-Steam shortcut dialogs untouched.
 */
export function nativeGamePages(props: unknown): PageEntry[] | undefined {
    if (!props || typeof props !== "object") return undefined;
    const pages = (props as { pages?: unknown }).pages;
    if (!Array.isArray(pages) || pages.length === 0 || pages.length > MAX_PAGES) return undefined;
    if ((pages[0] as PageEntry | undefined)?.route !== GENERAL_ROUTE) return undefined;
    for (const page of pages as PageEntry[]) {
        if (!page || typeof page.route !== "string" || !page.route.startsWith(ROUTE_PREFIX) || typeof page.link !== "string") {
            return undefined;
        }
        if (page.route === TIMEFREEZE_ROUTE) return undefined; // already injected
    }
    return pages as PageEntry[];
}

/** Extract the native Steam appid from a page link (`/app/<appid>/properties/<name>`). */
export function nativeAppIdOfLink(link: string): number | undefined {
    const raw = Number(link.split("/")[2]);
    if (!isNativeSteamAppId(raw)) return undefined;
    return normalizeAppId(raw);
}

/** Append the Timefreeze page as the last option in the Properties sidebar. */
export function insertTimefreezePage(pages: PageEntry[], entry: PageEntry): PageEntry[] {
    return [...pages, entry];
}
