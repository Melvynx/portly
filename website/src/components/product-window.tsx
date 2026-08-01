import {
  ChevronRight,
  Compass,
  Eraser,
  Network,
  Plus,
  RotateCw,
  SlidersHorizontal,
  Square,
} from "lucide-react";
import { projects, selectedPort } from "./portly-state";

/*
 * A reproduction of the real Portly window, not an illustration of one.
 * Every project, port, command and log line below is copied from
 * `portly status --json` and `portly logs Portly/website` on the machine that
 * builds this site, and the layout mirrors MainView.swift + ServerDetail.swift:
 * NavigationSplitView, a `.bar` info strip, and the live terminal underneath.
 */

/** The scrollback tail of the run that built this page. */
const hmrLines = [
  {
    time: "3:23:22 PM",
    channel: "ssr",
    action: "page reload",
    file: "src/routes/index.tsx",
  },
  {
    time: "3:23:26 PM",
    channel: "client",
    action: "hmr update",
    file: "/src/styles.css",
  },
  {
    time: "3:24:01 PM",
    channel: "ssr",
    action: "page reload",
    file: "src/styles.css",
  },
  {
    time: "3:24:05 PM",
    channel: "client",
    action: "hmr update",
    file: "/src/styles.css",
  },
];

const metrics = [
  ["PID", "41918"],
  ["Port", "3000"],
  ["Uptime", "4h 11m"],
];

export function ProductWindow({ compact = false }: { compact?: boolean }) {
  // The compact window is shorter, but it still has to contain the server the
  // info bar and terminal are describing.
  const shown = compact ? projects.slice(1, 4) : projects;

  return (
    <figure className={`window ${compact ? "window-compact" : ""}`}>
      <figcaption className="sr-only">
        The Portly window: five registered projects in the sidebar, each server
        showing its port and status, with the website server running on port
        3000 and its live terminal output on the right.
      </figcaption>

      {/* The reproduction is a picture of the app; the caption above describes
          it, so the pixels below stay out of the accessibility tree. */}
      <div className="window-bar" aria-hidden="true">
        <div className="traffic">
          <span />
          <span />
          <span />
        </div>

        <div className="window-title">
          <strong>website</strong>
          <span>Portly</span>
        </div>

        <div className="window-tools" aria-hidden="true">
          <Square size={11} fill="currentColor" strokeWidth={0} />
          <RotateCw size={12} />
          <Compass size={12} />
          <Eraser size={12} />
          <SlidersHorizontal size={12} />
        </div>
      </div>

      <div className="window-body" aria-hidden="true">
        <aside className="app-sidebar">
          <div className="app-sidebar-list">
            {shown.map((project) => {
              const Icon = project.icon;
              return (
                <section className="app-section" key={project.name}>
                  <p className="app-project">
                    <Icon
                      size={12}
                      className="app-project-icon"
                      style={{ color: project.color }}
                    />
                    <span>{project.name}</span>
                  </p>

                  {project.servers.map((server) => (
                    <p
                      className={`app-server ${
                        server.port === selectedPort ? "is-selected" : ""
                      }`}
                      key={server.name + server.port}
                    >
                      <i
                        className={`app-dot is-${server.state}`}
                        aria-hidden="true"
                      />
                      <span className="app-server-text">
                        <span className="app-server-name">{server.name}</span>
                        <code className="app-server-host">
                          localhost:{server.port}
                        </code>
                      </span>
                      {server.uptime ? (
                        <span className="app-uptime">{server.uptime}</span>
                      ) : null}
                    </p>
                  ))}
                </section>
              );
            })}
          </div>

          <div className="app-sidebar-actions">
            <span className="app-btn-prominent">
              <Plus size={11} />
              Add Project
            </span>
            <span className="app-btn-quiet">
              <Network size={11} />
              View Ports
              <ChevronRight size={10} className="app-btn-chevron" />
            </span>
          </div>
        </aside>

        <div className="app-detail">
          <div className="app-infobar">
            <span className="app-state">
              <i className="app-dot is-running" aria-hidden="true" />
              Running
            </span>
            {metrics.map(([label, value]) => (
              <span className="app-metric" key={label}>
                <small>{label}</small>
                <code>{value}</code>
              </span>
            ))}
          </div>

          <div className="app-terminal">
            <p>
              <span className="t-tag">[portly]</span> starting: corepack pnpm
              --dir website dev
            </p>
            <p className="t-space">
              <span className="t-dim">&gt;</span> portly-website@0.1.0 dev
            </p>
            <p>
              <span className="t-dim">&gt;</span> vite dev
            </p>
            <p className="t-space">
              <span className="t-vite">VITE v8.1.3</span>{" "}
              <span className="t-dim">ready in 412 ms</span>
            </p>
            <p className="t-space">
              <span className="t-green">➜</span> <strong>Local:</strong>{" "}
              <span className="t-link">http://localhost:3000/</span>
            </p>
            <p>
              <span className="t-green">➜</span> <strong>Network:</strong>{" "}
              <span className="t-dim">use --host to expose</span>
            </p>
            <p>
              <span className="t-green">➜</span>{" "}
              <span className="t-dim">press h + enter to show help</span>
            </p>

            {/* The taller window shows more of the same scrollback. */}
            {(compact ? hmrLines : hmrLines.slice(-2)).map((line, index) => (
              <p
                className={index === 0 ? "t-space" : undefined}
                key={line.time + line.file}
              >
                <span className="t-dim">{line.time}</span>{" "}
                <span className="t-cyan">[vite]</span>{" "}
                <span className="t-dim">({line.channel})</span> {line.action}{" "}
                <span className="t-link">{line.file}</span>
              </p>
            ))}

            <p className="t-caret">
              <span />
            </p>
          </div>
        </div>
      </div>
    </figure>
  );
}
