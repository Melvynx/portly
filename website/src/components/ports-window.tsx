import {
  AppWindowMac,
  ChevronDown,
  Compass,
  Lock,
  Network,
  RotateCw,
  Search,
  Settings2,
  Square,
  X,
} from "lucide-react";
import { projects } from "./portly-state";

/*
 * The Ports screen from PortsView.swift: one card per owning process, a badge
 * telling you whether Portly manages the listener, and a stop control that is
 * only offered for things it is allowed to stop.
 */

type Kind = "Managed" | "External";

type Port = {
  port: number;
  name: string;
  detail: string;
  kind: Kind;
};

type Group = {
  name: string;
  detail: string;
  color: string;
  summary: string;
  ports: Port[];
};

const groups: Group[] = [
  {
    name: "Portly",
    detail: "~/Developer/ideas/portly",
    color: "#338cff",
    summary: "1 server",
    ports: [
      {
        port: 3000,
        name: "website",
        detail: "node · PID 41954 · melvynx",
        kind: "Managed",
      },
    ],
  },
  {
    name: "lumail.io",
    detail: "~/Developer/projects/lumail.io",
    color: "#64d2ff",
    summary: "1 server",
    ports: [
      {
        port: 3002,
        name: "dev",
        detail: "node · PID 41901 · melvynx",
        kind: "Managed",
      },
    ],
  },
  {
    name: "node",
    detail: "Started outside Portly",
    color: "#98989d",
    summary: "1 external",
    ports: [
      {
        port: 3001,
        name: "node",
        detail: "next-server · PID 91724 · melvynx",
        kind: "External",
      },
    ],
  },
];

const summary = "8 listening · 4 managed servers · 1 external · 3 system";

/*
 * macOS's own listeners, grouped by the service that owns them exactly as
 * SystemPortsCard does. Portly shows them so a port is never a mystery, and
 * refuses to stop them.
 */
const systemServices = [
  {
    name: "ControlCenter",
    ports: [
      { port: 5000, detail: "ControlCenter · PID 660 · melvynx" },
      { port: 7000, detail: "ControlCenter · PID 660 · melvynx" },
    ],
  },
  {
    name: "rapportd",
    ports: [{ port: 49152, detail: "rapportd · PID 630 · melvynx" }],
  },
];

export function PortsWindow() {
  return (
    <figure className="window window-ports">
      <figcaption className="sr-only">
        The Ports screen: every listening TCP port grouped by the process that
        owns it, with the servers Portly manages marked Managed and a process
        started outside Portly marked External.
      </figcaption>

      {/* Same as the main window: a picture, described by the caption above. */}
      <div className="window-bar" aria-hidden="true">
        <div className="traffic">
          <span />
          <span />
          <span />
        </div>
        <div className="window-title">
          <strong>Ports</strong>
        </div>
        <div className="window-tools">
          <RotateCw size={12} />
        </div>
      </div>

      <div className="ports-head" aria-hidden="true">
        <span className="ports-glyph">
          <Network size={19} />
        </span>
        <span className="ports-title">
          <strong>Active ports</strong>
          <small>{summary}</small>
        </span>
        <span className="ports-search">
          <Search size={12} />
          Search ports
        </span>
      </div>

      <div className="ports-list" aria-hidden="true">
        {groups.map((group) => (
          <section className="ports-card" key={group.name}>
            <header className="ports-card-head">
              <i className="ports-dot" style={{ background: group.color }} />
              <span className="ports-card-title">
                <strong>{group.name}</strong>
                <small>{group.detail}</small>
              </span>
              <small className="ports-card-summary">{group.summary}</small>
            </header>

            {group.ports.map((port) => (
              <div className="ports-row" key={port.port}>
                <code className="ports-number">:{port.port}</code>
                <span className="ports-body">
                  <span className="ports-name">
                    {port.name}
                    <em className={`ports-badge is-${port.kind.toLowerCase()}`}>
                      {port.kind}
                    </em>
                  </span>
                  <code className="ports-detail">{port.detail}</code>
                </span>
                <span className="ports-actions" aria-hidden="true">
                  <Compass size={13} />
                  {port.kind === "Managed" ? (
                    <Square size={11} fill="currentColor" strokeWidth={0} />
                  ) : (
                    <X size={13} className="ports-danger" />
                  )}
                </span>
              </div>
            ))}
          </section>
        ))}

        {/* macOS owns these, so every row is read only and marked Protected. */}
        <section className="ports-card ports-system">
          <header className="ports-card-head">
            <span className="ports-system-glyph" aria-hidden="true">
              <Settings2 size={13} />
            </span>
            <span className="ports-card-title">
              <strong>System</strong>
              <small>Protected background services · Read only</small>
            </span>
            <small className="ports-card-summary">2 services · 3 ports</small>
            <ChevronDown size={11} className="ports-chevron" />
          </header>

          {systemServices.map((service) => (
            <div key={service.name}>
              <p className="ports-service">
                <AppWindowMac size={11} className="ports-service-glyph" />
                <strong>{service.name}</strong>
                <small>
                  {service.ports.length}{" "}
                  {service.ports.length === 1 ? "port" : "ports"}
                </small>
              </p>

              {service.ports.map((port) => (
                <div className="ports-row" key={port.port}>
                  <code className="ports-number">:{port.port}</code>
                  <span className="ports-body">
                    <span className="ports-name">
                      {service.name}
                      <em className="ports-badge is-protected">Protected</em>
                    </span>
                    <code className="ports-detail">{port.detail}</code>
                  </span>
                  <span className="ports-actions" aria-hidden="true">
                    <Lock size={11} className="ports-lock" />
                  </span>
                </div>
              ))}
            </div>
          ))}
        </section>

        <p className="ports-note">
          {projects.length} projects registered. Portly sends SIGTERM only when
          you ask it to.
        </p>
      </div>
    </figure>
  );
}
