import { createFileRoute } from "@tanstack/react-router";
import {
  ArrowUpRight,
  Check,
  ChevronRight,
  Copy,
  Download,
  Play,
  Square as SquareIcon,
  Terminal as TerminalIcon,
  TriangleAlert,
} from "lucide-react";
import type { ReactNode } from "react";
import { useState } from "react";
import { AgentConsole } from "../components/agent-console";
import { DuplicateDemo } from "../components/duplicate-demo";
import { PortlyMark } from "../components/portly-mark";
import { projects, runningSummary } from "../components/portly-state";
import { PortsWindow } from "../components/ports-window";
import { ProductWindow } from "../components/product-window";

const repoUrl = "https://github.com/Melvynx/portly";
const downloadUrl = `${repoUrl}/releases/latest/download/Portly-macOS.zip`;
/* Must be paste-and-run: same three steps the install block below prints. */
const installCommand = `git clone ${repoUrl}.git && cd portly && ./build.sh --run`;

export const Route = createFileRoute("/")({
  component: LandingPage,
});

const facts = [
  ["Native Swift 6", "One 4 MB app bundle. No Electron, no Node daemon."],
  [
    "127.0.0.1 only",
    "The control API can spawn processes, so it never binds to the network.",
  ],
  [
    "Real PTYs",
    "Colors, prompts, and scrollback survive the way they do in your terminal.",
  ],
  [
    "MIT licensed",
    "Every line that can start a process is readable in the repo.",
  ],
];

const capabilities = [
  {
    title: "Process supervision",
    body: "Each server runs through zsh -lc in a real pseudo terminal, so nvm, mise, and your shell PATH behave exactly as they do when you type the command yourself.",
    detail: "PORT · PORTLY=1 · PORTLY_SERVER",
  },
  {
    title: "Health, not liveness",
    body: "A TCP probe on the configured port, or an HTTP path with an expected status. A process that is alive but not serving your route is reported unhealthy.",
    detail: "healthIntervalSeconds: 10",
  },
  {
    title: "Crash recovery",
    body: "Unhealthy servers restart automatically until the retry budget runs out, then park as failed with the last exit code and error still visible.",
    detail: "maxRestartAttempts: 5",
  },
  {
    title: "Port ownership",
    body: "Ask who holds a port and get the PID, the command, and the user. Portly sends SIGTERM only when you ask it to, and never adopts an unknown process on its own.",
    detail: "portly port 3000 --json",
  },
  {
    title: "Logs that outlive the tab",
    body: "In-memory scrollback for the app plus a rotating file per server, readable from the CLI long after the terminal that started it is gone.",
    detail: "~/.config/portly/logs/",
  },
  {
    title: "One hand-editable config",
    body: "Projects, commands, ports, and health checks live in a single JSON file that Portly watches. Edit it, commit it, or let the app write it.",
    detail: "~/.config/portly/config.json",
  },
  {
    title: "Launch at login",
    body: "A per-user LaunchAgent that carries the servers running at handoff into the supervised session, and gives them back when you disable it.",
    detail: "portly forever enable",
  },
  {
    title: "Loopback HTTP API",
    body: "Every CLI action is a route. Responses are JSON envelopes with ok, data, and error, which is what makes the whole thing scriptable.",
    detail: "GET /status · POST /start",
  },
];

function LandingPage() {
  const softwareJsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "Portly",
    applicationCategory: "DeveloperApplication",
    operatingSystem: "macOS 14 or newer",
    url: "https://portly.melvynx.dev",
    downloadUrl,
    softwareVersion: "0.1.0",
    license: "https://opensource.org/license/mit",
    codeRepository: repoUrl,
    description:
      "A native macOS supervisor that gives AI coding agents one source of truth for local development servers.",
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(softwareJsonLd) }}
      />
      <SiteHeader />

      <main id="main-content">
        <section className="hero">
          <div className="hero-copy">
            <a className="tag" href={`${repoUrl}/releases`}>
              <i className="dot dot-live" />
              v0.1.0 for macOS 14+
              <ChevronRight size={13} aria-hidden="true" />
            </a>
            <h1>Your agents keep starting the same server.</h1>
            <p className="lede">
              Portly runs it once. Every agent, terminal, and task then reads
              the same live state: what is running, on which port, under which
              PID, and whether it is actually healthy.
            </p>
            <div className="actions">
              <a className="btn btn-primary" href={downloadUrl}>
                <Download size={16} aria-hidden="true" />
                Download for macOS
              </a>
              <a className="btn btn-ghost" href={repoUrl}>
                <GithubMark size={16} />
                Source
              </a>
            </div>
            <CopyLine value={installCommand} />
          </div>

          <div className="hero-stage">
            <ProductWindow />
          </div>
        </section>

        <ul className="facts">
          {facts.map(([title, body]) => (
            <li key={title}>
              <strong>{title}</strong>
              <span>{body}</span>
            </li>
          ))}
        </ul>

        <Section
          id="problem"
          kicker="The cost"
          title="Five parallel tasks, five copies of your app."
          lede="An agent starts a background job because nothing told it the server already exists. Do that across four terminals and two editors and you get duplicate process trees, fallback ports nobody wrote down, logs split across tabs, and a laptop doing the same work five times over."
        >
          <DuplicateDemo />
        </Section>

        <Section
          id="agents"
          kicker="Agent interface"
          title="Inspect first. Launch only if needed."
          lede="Portly ships a skill that Claude Code, Codex, and Cursor pick up from ~/.agents/skills/portly. It teaches one rule: read the live state before you spawn anything. The CLI answers in JSON so the agent never has to parse a spinner."
          aside={
            <a className="link" href={`${repoUrl}/tree/main/skills/portly`}>
              Read the skill
              <ArrowUpRight size={14} aria-hidden="true" />
            </a>
          }
        >
          <AgentConsole />
        </Section>

        <Section
          id="app"
          kicker="The app"
          title="A native window, a menu bar, nothing in the background."
          lede="Portly looks and behaves like part of macOS. It is the same supervisor whether you drive it by hand, from the menu bar, or through the CLI."
        >
          <div className="tour">
            <figure className="tour-main">
              <PortsWindow />
              <figcaption>
                <strong>Every listening port, grouped by owner</strong>
                <span>
                  What Portly manages, what something else started, and what
                  macOS will not let anyone touch.
                </span>
              </figcaption>
            </figure>

            <div className="tour-side">
              <MenuBarCard />
              <TakeoverCard />
            </div>
          </div>
        </Section>

        <Section
          id="capabilities"
          kicker="Capabilities"
          title="What the supervisor actually does."
          lede="No cloud account, no dashboard subscription, no process manager buried inside an agent framework."
        >
          <ul className="specs">
            {capabilities.map((item) => (
              <li key={item.title}>
                <h3>{item.title}</h3>
                <p>{item.body}</p>
                <code>{item.detail}</code>
              </li>
            ))}
          </ul>
        </Section>

        <section className="install" id="install">
          <div className="install-copy">
            <p className="kicker">Install</p>
            <h2>Two lines, then it is yours.</h2>
            <p className="lede">
              The script builds the app, ad-hoc signs it, installs the portly
              binary on your PATH, and drops the agent skill in
              ~/.agents/skills/portly.
            </p>
            <div className="actions">
              <a className="btn btn-primary" href={downloadUrl}>
                <Download size={16} aria-hidden="true" />
                Download the build
              </a>
              <a className="btn btn-ghost" href={`${repoUrl}#install`}>
                <GithubMark size={16} />
                Build from source
              </a>
            </div>
          </div>

          <pre className="install-shell" aria-label="Install commands">
            <span>
              <b>$</b> git clone {repoUrl}.git{"\n"}
            </span>
            <span>
              <b>$</b> cd portly && ./build.sh --run{"\n"}
            </span>
            <span>{"\n"}</span>
            <span className="ok">
              ✓ Portly.app installed in /Applications{"\n"}
            </span>
            <span className="ok">✓ portly on PATH{"\n"}</span>
            <span className="ok">
              ✓ skill linked at ~/.agents/skills/portly{"\n"}
            </span>
          </pre>
        </section>
      </main>

      <SiteFooter />
    </>
  );
}

function SiteHeader() {
  return (
    <header className="site-header">
      <div className="header-inner">
        <a className="brand" href="/">
          <PortlyMark size={26} />
          Portly
        </a>
        <nav aria-label="Main">
          <a href="#problem">Why</a>
          <a href="#agents">Agents</a>
          <a href="#app">App</a>
          <a href="#capabilities">Capabilities</a>
        </nav>
        <div className="header-actions">
          <a
            className="header-source"
            href={repoUrl}
            aria-label="Source on GitHub"
          >
            <GithubMark size={16} />
          </a>
          <a className="btn btn-small" href={downloadUrl}>
            Download
          </a>
        </div>
      </div>
    </header>
  );
}

function Section({
  id,
  kicker,
  title,
  lede,
  aside,
  children,
}: {
  id: string;
  kicker: string;
  title: string;
  lede: string;
  aside?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="section" id={id}>
      <div className="section-head">
        <div>
          <p className="kicker">{kicker}</p>
          <h2>{title}</h2>
          <p className="lede">{lede}</p>
        </div>
        {aside}
      </div>
      {children}
    </section>
  );
}

function CopyLine({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);

  return (
    <button
      type="button"
      className={`copy-line ${copied ? "is-copied" : ""}`}
      onClick={() => {
        void navigator.clipboard?.writeText(value);
        setCopied(true);
        window.setTimeout(() => setCopied(false), 1600);
      }}
    >
      <code>
        <b>$</b> {value}
      </code>
      {copied ? (
        <Check size={14} aria-hidden="true" />
      ) : (
        <Copy size={14} aria-hidden="true" />
      )}
      <span className="sr-only">
        {copied ? "Command copied" : "Copy install command"}
      </span>
    </button>
  );
}

/* The 320pt popover from MenuBarContent.swift, over the same machine state. */
function MenuBarCard() {
  return (
    <figure className="card menubar-card">
      <div className="card-surface" aria-hidden="true">
        <div className="menubar-head">
          <strong>Portly</strong>
          <span>{runningSummary}</span>
        </div>

        {projects.map((project) => {
          const Icon = project.icon;
          return (
            <div className="menubar-group" key={project.name}>
              <p className="menubar-project">
                <Icon size={12} style={{ color: project.color }} />
                {project.name}
                <span className="menubar-project-actions" aria-hidden="true">
                  <Play size={9} fill="currentColor" strokeWidth={0} />
                  <SquareIcon size={9} fill="currentColor" strokeWidth={0} />
                </span>
              </p>

              {project.servers.map((server) => (
                <p className="menubar-row" key={server.name}>
                  <i className={`app-dot is-${server.state}`} />
                  <span>{server.name}</span>
                  <code>:{server.port}</code>
                  <span className="menubar-row-action" aria-hidden="true">
                    {server.state === "running" ? (
                      <SquareIcon
                        size={9}
                        fill="currentColor"
                        strokeWidth={0}
                      />
                    ) : (
                      <Play size={9} fill="currentColor" strokeWidth={0} />
                    )}
                  </span>
                </p>
              ))}
            </div>
          );
        })}

        <div className="menubar-foot">
          <span>Open Portly</span>
          <span>Ports</span>
          <span className="menubar-foot-end">Stop All</span>
          <span>Quit</span>
        </div>
      </div>
      <figcaption>
        <strong>Menu bar</strong>
        <span>
          Start, stop, and check every server without leaving the app you are
          in.
        </span>
      </figcaption>
    </figure>
  );
}

function TakeoverCard() {
  return (
    <figure className="card takeover-card">
      <div className="card-surface" aria-hidden="true">
        <div className="takeover-banner">
          <TriangleAlert size={15} className="takeover-icon" />
          <div className="takeover-text">
            <strong>Running outside Portly</strong>
            <span>node (pid 91724) is using port 3001.</span>
          </div>
          <div className="takeover-actions">
            <span>Stop process</span>
            <span>Move to Portly</span>
          </div>
        </div>

        <div className="takeover-under">
          <p className="takeover-under-title">
            <TerminalIcon size={22} strokeWidth={1.4} />
            Server is stopped
          </p>
          <p className="takeover-under-body">
            Start dev to see its live terminal output.
          </p>
          <span className="takeover-start" aria-hidden="true">
            <Play size={11} fill="currentColor" strokeWidth={0} />
            Start
          </span>
        </div>
      </div>
      <figcaption>
        <strong>Explicit takeover</strong>
        <span>
          You see who owns the port before anything is stopped. Nothing is
          killed silently.
        </span>
      </figcaption>
    </figure>
  );
}

function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="footer-inner">
        <div className="footer-brand">
          <PortlyMark size={28} />
          <div>
            <strong>Portly</strong>
            <span>Local servers, under control.</span>
          </div>
        </div>
        <nav aria-label="Footer">
          <a href={repoUrl}>Source</a>
          <a href={`${repoUrl}/releases`}>Releases</a>
          <a href={`${repoUrl}/blob/main/SECURITY.md`}>Security</a>
          <a href={`${repoUrl}/blob/main/CONTRIBUTING.md`}>Contributing</a>
          <a href={`${repoUrl}/blob/main/LICENSE`}>MIT</a>
        </nav>
        <p>
          Built by <a href="https://melvynx.com">Melvynx</a>
        </p>
      </div>
    </footer>
  );
}

function GithubMark({ size }: { size: number }) {
  return (
    <svg
      aria-hidden="true"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
    >
      <path d="M12 .7A11.3 11.3 0 0 0 8.4 22.8c.6.1.8-.3.8-.6v-2.2c-3.4.7-4.1-1.4-4.1-1.4-.5-1.4-1.3-1.8-1.3-1.8-1.1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1.1 1.8 2.8 1.3 3.5 1 .1-.8.4-1.3.8-1.6-2.7-.3-5.6-1.4-5.6-6A4.7 4.7 0 0 1 5.7 7.4c-.1-.3-.5-1.6.1-3.3 0 0 1-.3 3.5 1.3a12 12 0 0 1 6.3 0C18 3.7 19.1 4 19.1 4c.6 1.7.2 3 .1 3.3a4.7 4.7 0 0 1 1.2 3.2c0 4.7-2.9 5.7-5.6 6 .4.4.8 1.1.8 2.2v3.4c0 .3.2.7.8.6A11.3 11.3 0 0 0 12 .7Z" />
    </svg>
  );
}
