const PREFIX = "[steam-timefreeze]";

export const logger = {
    info(message: string, ...args: unknown[]): void {
        console.log(`${PREFIX} ${message}`, ...args);
    },
    warn(message: string, ...args: unknown[]): void {
        console.warn(`${PREFIX} ${message}`, ...args);
    },
    error(message: string, ...args: unknown[]): void {
        console.error(`${PREFIX} ${message}`, ...args);
    },
};
