import { ExternalLink, Play, RotateCw, Square, Terminal } from "lucide-react";

const projects = [
  {
    name: "NowStack",
    icon: "N",
    color: "blue",
    server: "web",
    port: "3000",
    active: true,
  },
  {
    name: "Lumail",
    icon: "L",
    color: "purple",
    server: "workers",
    port: "3001",
    active: false,
  },
  {
    name: "Codelynx",
    icon: "C",
    color: "orange",
    server: "docs",
    port: "5173",
    active: false,
  },
];

export function ProductWindow({ compact = false }: { compact?: boolean }) {
  return (
    <figure
      className={`product-window ${compact ? "product-window-compact" : ""}`}
    >
      <figcaption className="sr-only">
        Portly desktop application showing one healthy NowStack web server on
        port 3000.
      </figcaption>
      <div className="window-chrome">
        <div className="traffic-lights" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <span className="window-title">Portly</span>
        <div className="window-actions" aria-hidden="true">
          <Play size={13} fill="currentColor" />
          <Square size={12} fill="currentColor" />
          <RotateCw size={13} />
          <ExternalLink size={13} />
        </div>
      </div>
      <div className="window-body">
        <aside className="app-sidebar" aria-label="Projects">
          <div className="sidebar-label">Projects</div>
          {projects.map((project) => (
            <div
              key={project.name}
              className={`sidebar-project ${project.active ? "is-selected" : ""}`}
            >
              <div className={`project-icon project-${project.color}`}>
                {project.icon}
              </div>
              <div className="project-copy">
                <strong>{project.name}</strong>
                <span>
                  <i className="status-dot status-green" /> {project.server}
                </span>
              </div>
              <code>:{project.port}</code>
            </div>
          ))}
          <div className="sidebar-add">＋ Add project</div>
        </aside>
        <div className="app-main">
          <div className="server-bar">
            <div>
              <span className="status-dot status-green" />
              <strong>Running</strong>
            </div>
            <span>
              <small>PID</small>
              <code>82104</code>
            </span>
            <span>
              <small>PORT</small>
              <code>3000</code>
            </span>
            <span>
              <small>UPTIME</small>
              <code>2h 14m</code>
            </span>
            <span>
              <small>RESTARTS</small>
              <code>0</code>
            </span>
          </div>
          <div className="terminal-pane">
            <div className="terminal-heading">
              <Terminal size={13} /> nowstack / web
            </div>
            <p>
              <span className="term-muted">$</span> pnpm dev
            </p>
            <p>
              <span className="term-blue">➜</span> Local:{" "}
              <span className="term-link">http://localhost:3000/</span>
            </p>
            <p>
              <span className="term-blue">➜</span> Network: use --host to expose
            </p>
            <p className="term-space">
              <span className="term-green">✓</span> ready in 438 ms
            </p>
            <p>
              <span className="term-muted">portly</span> health check passed{" "}
              <span className="term-muted">200 OK</span>
            </p>
            {!compact && (
              <>
                <p>
                  <span className="term-muted">portly</span> shared state
                  available on <span className="term-link">127.0.0.1:7737</span>
                </p>
                <p className="terminal-cursor">
                  <span>▌</span>
                </p>
              </>
            )}
          </div>
        </div>
      </div>
    </figure>
  );
}
