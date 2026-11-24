const PREFIX = "[steam-timefreeze]";

type LogListener = (level: "info" | "warn" | "error", message: string) => void;
let listener: LogListener | null = null;

export function setLogListener(fn: LogListener | null): void {
    listener = fn;
}

export const logger = {
    info(message: string, ...args: unknown[]): void {
        console.log(`${PREFIX} ${message}`, ...args);
        listener?.("info", args.length > 0 ? `${message} ${args.map((a) => JSON.stringify(a)).join(" ")}` : message);
    },
    warn(message: string, ...args: unknown[]): void {
        console.warn(`${PREFIX} ${message}`, ...args);
        listener?.("warn", args.length > 0 ? `${message} ${args.map((a) => JSON.stringify(a)).join(" ")}` : message);
    },
    error(message: string, ...args: unknown[]): void {
        console.error(`${PREFIX} ${message}`, ...args);
        listener?.("error", args.length > 0 ? `${message} ${args.map((a) => JSON.stringify(a)).join(" ")}` : message);
    },
};
