/**
 * Surface `properties`: injects a "Timefreeze" page as the last tab in every
 * native Steam game's Properties dialog.
 *
 * Mirrors steam-cartridges/frontend/surfaces/properties/index.ts:
 * recognises `jsx(Sidebar, { pages, ... })` by prop shape (never module id),
 * wraps the original component once per type (WeakMap) so React never remounts
 * the dialog, and appends our page with a valid `route` and `link`.
 */
import { createElement, type ComponentType } from "react";
import { keepJsxPatched } from "../../steam/jsx-hook";
import { jsxRuntime } from "../../steam/modules";
import { insertTimefreezePage, nativeAppIdOfLink, nativeGamePages, TIMEFREEZE_ROUTE, type PageEntry } from "./core";
import { PageBoundary } from "./boundary";

export interface PropertiesSurfaceOptions {
    body: ComponentType<{ appid: number }>;
    log?: (message: string) => void;
}

let opts: PropertiesSurfaceOptions = {
    body: () => null,
};
let hook: ReturnType<typeof keepJsxPatched> | undefined;
const wrappers = new WeakMap<object, ComponentType<{ pages: PageEntry[] }>>();
let injectedCount = 0;

function wrapperFor(type: object): ComponentType<{ pages: PageEntry[] }> {
    let wrapper = wrappers.get(type);
    if (!wrapper) {
        const original = type as unknown as ComponentType<{ pages: PageEntry[] }>;
        wrapper = function TimefreezeSidebar(props: { pages: PageEntry[] }) {
            if (!props || typeof props !== "object") return null;
            try {
                const pages = nativeGamePages(props);
                const appid = pages ? nativeAppIdOfLink(pages[0]?.link ?? "") : undefined;
                if (pages && appid !== undefined) {
                    const rawIdSegment = pages[0]!.link.split("/")[2];
                    const page: PageEntry = {
                        title: "Timefreeze",
                        route: TIMEFREEZE_ROUTE,
                        link: `/app/${rawIdSegment}/properties/timefreeze`,
                        content: createElement(
                            "div",
                            { className: "DialogBody" },
                            createElement(PageBoundary, { appid, log: opts.log }, createElement(opts.body, { appid })),
                        ),
                    };
                    injectedCount++;
                    return createElement(original, { ...props, pages: insertTimefreezePage(pages, page) });
                }
            } catch (err) {
                opts.log?.(`TimefreezeSidebar error: ${String(err)}`);
            }
            return createElement(original, props);
        };
        wrappers.set(type, wrapper);
    }
    return wrapper;
}

function replaceType(type: unknown, props: unknown): unknown {
    // Cheapest check first: almost no element has a `pages` prop.
    if (!props || typeof props !== "object" || !("pages" in props)) return undefined;
    try {
        if (typeof type !== "function" && (typeof type !== "object" || type === null)) return undefined;
        if (!nativeGamePages(props)) return undefined;
        return wrapperFor(type as object);
    } catch (err) {
        opts.log?.(`replaceType error: ${String(err)}`);
        return undefined;
    }
}

export function installPropertiesSurface(options: PropertiesSurfaceOptions): void {
    opts = options;
    const runtime = jsxRuntime();
    if (!runtime) {
        opts.log?.("jsxRuntime unavailable; Timefreeze Properties tab not installed.");
        return;
    }
    hook = keepJsxPatched(
        runtime as unknown as Record<"jsx" | "jsxs", (type: unknown, props: unknown, key?: unknown) => unknown>,
        {
            label: "timefreeze-properties",
            replaceType,
        },
    );
}

export function uninstallPropertiesSurface(): void {
    hook?.dispose();
    hook = undefined;
}

export function propertiesDiagnostics(): { installed: boolean; injectedCount: number } {
    return { installed: !!hook, injectedCount };
}
