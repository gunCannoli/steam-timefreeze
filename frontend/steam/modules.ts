import { findModuleByExport } from "@steambrew/client";

/** Steam's react/jsx-runtime module: the one every jsx hook patches (steam/jsx-hook.ts). */
export interface JsxRuntime {
    jsx(type: unknown, props: unknown, key?: unknown): unknown;
    jsxs(type: unknown, props: unknown, key?: unknown): unknown;
}

let cachedJsxRuntime: JsxRuntime | undefined;

/**
 * Steam's jsx runtime, found by its export names (never a module id) and remembered once found.
 */
export function jsxRuntime(): JsxRuntime | undefined {
    if (cachedJsxRuntime) return cachedJsxRuntime;
    const found = findModuleByExport(
        (moduleExport: unknown, exportName?: unknown) =>
            (exportName === "jsx" || exportName === "jsxs") && typeof moduleExport === "function",
    ) as JsxRuntime | undefined;
    if (!found || typeof found.jsx !== "function" || typeof found.jsxs !== "function") return undefined;
    cachedJsxRuntime = found;
    return found;
}
