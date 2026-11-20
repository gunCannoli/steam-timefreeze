/**
 * Error boundary around the Timefreeze Properties page body so a render error
 * never takes down Steam's Properties dialog.
 */
import { Component, createElement, type ReactNode } from "react";

interface Props {
    appid: number;
    log?: (message: string) => void;
    children?: ReactNode;
}
interface State {
    error?: Error;
}

export class PageBoundary extends Component<Props, State> {
    override state: State = {};

    static getDerivedStateFromError(error: Error): State {
        return { error };
    }

    override componentDidCatch(error: Error): void {
        try {
            this.props.log?.(`Timefreeze page failed to render: ${error?.name ?? "Error"}: ${error?.message ?? String(error)}`);
        } catch {
            /* logging must never throw inside a boundary */
        }
    }

    override render(): ReactNode {
        if (!this.state.error) return this.props.children;
        return createElement(
            "div",
            { style: { padding: "12px 16px", color: "#e5a00d" } },
            createElement("div", null, "Timefreeze hit an error and stopped rendering. The Properties window is unaffected."),
            createElement(
                "button",
                { style: { marginTop: 8 }, onClick: () => this.setState({ error: undefined }) },
                "Try again",
            ),
        );
    }
}
