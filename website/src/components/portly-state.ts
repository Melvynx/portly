import { Box, Boxes, Package, Zap } from "lucide-react";
import type { LucideIcon } from "lucide-react";

/*
 * The machine state this site was built from, copied verbatim from
 * `portly status --json`. The product window and the menu bar popover both read
 * it, so the two screenshots can never disagree with each other.
 */

export type ServerState = "running" | "stopped";

export type Server = {
  name: string;
  port: number;
  state: ServerState;
  uptime?: string;
};

export type Project = {
  name: string;
  /** lucide stand-in for the SF Symbol stored in the project config */
  icon: LucideIcon;
  /** the exact hex the app renders that symbol in */
  color: string;
  servers: Server[];
};

export const projects: Project[] = [
  {
    name: "Codelynx dev v2",
    icon: Package,
    color: "#0a84ff",
    servers: [{ name: "dev", port: 5173, state: "running", uptime: "4h 12m" }],
  },
  {
    name: "codeline-app",
    icon: Box,
    color: "#64d2ff",
    servers: [{ name: "dev", port: 5174, state: "running", uptime: "4h 12m" }],
  },
  {
    name: "lumail.io",
    icon: Zap,
    color: "#64d2ff",
    servers: [
      { name: "dev", port: 3002, state: "running", uptime: "4h 12m" },
      { name: "dev-services", port: 3003, state: "stopped" },
    ],
  },
  {
    name: "Portly",
    icon: Zap,
    color: "#338cff",
    servers: [
      { name: "website", port: 3000, state: "running", uptime: "4h 11m" },
    ],
  },
  {
    name: "NOW.TS",
    icon: Boxes,
    color: "#2563eb",
    servers: [{ name: "web", port: 3004, state: "stopped" }],
  },
];

/** The server the window has selected: Portly's own site, on port 3000. */
export const selectedPort = 3000;

export const runningSummary = "4/6 running";
