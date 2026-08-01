import { createFileRoute } from "@tanstack/react-router";
import {
  ArrowDown,
  ArrowRight,
  Bot,
  Check,
  ChevronRight,
  CircleGauge,
  Code2,
  Download,
  ExternalLink,
  HeartPulse,
  ListTree,
  Network,
  Play,
  RefreshCw,
  ShieldCheck,
  Square,
  SquareTerminal,
  X,
} from "lucide-react";
import type { ReactNode } from "react";
import { ProcessDemo } from "../components/process-demo";
import { ProductWindow } from "../components/product-window";
import { PortlyMark } from "../components/portly-mark";

const repoUrl = "https://github.com/Melvynx/portly";
const downloadUrl = `${repoUrl}/releases/latest/download/Portly-macOS.zip`;

export const Route = createFileRoute("/")({
  component: LandingPage,
});

const painPoints = [
  "Every agent guesses whether the app is already running.",
  "Each new task grabs another port and starts another process tree.",
  "Logs, health, and ownership disappear across terminal tabs.",
  "Your laptop pays the cost for context the agent never received.",
];

const benefits = [
  "One live source of truth for projects, servers, ports, PIDs, and health.",
  "A stable CLI and JSON API that agents can inspect before they act.",
  "Persistent PTYs and logs without duplicate background jobs.",
  "Explicit takeovers when a server was started outside Portly.",
];

const features = [
  {
    icon: Bot,
    title: "Built for coding agents",
    body: "Agents inspect structured live state before launching anything, then reuse the process that already exists.",
  },
  {
    icon: SquareTerminal,
    title: "Real interactive terminals",
    body: "Each server runs in a true PTY with readable output, persistent scrollback, and log files you can inspect later.",
  },
  {
    icon: HeartPulse,
    title: "Health, not guesswork",
    body: "Port and HTTP checks show whether a process is merely alive or actually serving the route you expect.",
  },
  {
    icon: RefreshCw,
    title: "Crash recovery",
    body: "Restart unhealthy processes automatically, cap retry loops, and keep the last exit and failure visible.",
  },
  {
    icon: Network,
    title: "Safe port ownership",
    body: "See exactly what owns a port. Portly never kills an unknown process without an explicit takeover.",
  },
  {
    icon: ShieldCheck,
    title: "Local by design",
    body: "The control API binds to 127.0.0.1 only. Your commands, paths, logs, and project state stay on your Mac.",
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
    <div className="site-shell">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(softwareJsonLd) }}
      />
      <SiteHeader />

      <main id="main-content">
        <section className="hero section-pad">
          <div className="hero-glow" aria-hidden="true" />
          <div className="hero-copy">
            <div className="eyebrow">
              <span className="status-dot status-green" />
              Native macOS server supervisor
            </div>
            <h1>
              Stop launching the same app <em>five times.</em>
            </h1>
            <p className="hero-description">
              Portly gives every AI coding agent the same live context for your
              local servers—what is running, where it runs, and whether it is
              healthy.
            </p>
            <div className="hero-actions">
              <a className="button button-primary" href={downloadUrl}>
                <Download size={17} aria-hidden="true" />
                Download for macOS
              </a>
              <a className="button button-secondary" href={repoUrl}>
                <GithubLogo size={17} />
                View source
              </a>
            </div>
            <div
              className="hero-meta"
              aria-label="Platform requirements and license"
            >
              <span>macOS 14+</span>
              <i aria-hidden="true" />
              <span>Swift 6</span>
              <i aria-hidden="true" />
              <span>MIT licensed</span>
            </div>
          </div>

          <div className="hero-product">
            <div className="hero-product-label">
              <span>
                <CircleGauge size={15} aria-hidden="true" /> Live server state
              </span>
              <code>localhost:7737</code>
            </div>
            <ProductWindow />
          </div>

          <a
            className="scroll-cue"
            href="#problem"
            aria-label="Read about the problem Portly solves"
          >
            <ArrowDown size={17} aria-hidden="true" />
          </a>
        </section>

        <div className="proof-strip" aria-label="Product highlights">
          <span>
            <Check size={14} /> One process per server
          </span>
          <span>
            <Check size={14} /> Agent-ready JSON
          </span>
          <span>
            <Check size={14} /> Persistent local logs
          </span>
          <span>
            <Check size={14} /> Loopback-only API
          </span>
        </div>

        <section className="problem section-pad" id="problem">
          <SectionHeading
            kicker="The problem"
            title={
              <>
                Five tasks should not mean <em>five copies of your app.</em>
              </>
            }
            description="Agents start background jobs because they lack shared runtime context. The result is duplicate process trees, random fallback ports, fragmented logs, and a laptop doing five times the work."
          />

          <div className="comparison-grid">
            <article className="comparison-card comparison-card-bad">
              <div className="comparison-label">
                <X size={15} /> Without Portly
              </div>
              <div className="process-math">
                <strong>5</strong>
                <span>agents</span>
                <i>×</i>
                <strong>5</strong>
                <span>apps</span>
                <i>=</i>
                <strong className="bad-number">25</strong>
                <span>processes</span>
              </div>
              <ul>
                {painPoints.map((item) => (
                  <li key={item}>
                    <X size={15} aria-hidden="true" />
                    {item}
                  </li>
                ))}
              </ul>
            </article>
            <article className="comparison-card comparison-card-good">
              <div className="comparison-label">
                <Check size={15} /> With Portly
              </div>
              <div className="process-math">
                <strong>5</strong>
                <span>agents</span>
                <i>→</i>
                <strong className="good-number">1</strong>
                <span>supervisor</span>
                <i>→</i>
                <strong>1</strong>
                <span>process</span>
              </div>
              <ul>
                {benefits.map((item) => (
                  <li key={item}>
                    <Check size={15} aria-hidden="true" />
                    {item}
                  </li>
                ))}
              </ul>
            </article>
          </div>
        </section>

        <section className="demo-section section-pad" id="demo">
          <SectionHeading
            kicker="Interactive demo"
            title={
              <>
                Give the agent context <em>before it acts.</em>
              </>
            }
            description="Portly turns a hidden runtime into explicit shared state. Compare the process sprawl with the supervised path."
          />
          <ProcessDemo />
        </section>

        <section className="screenshots section-pad" id="screenshots">
          <div className="split-heading">
            <SectionHeading
              kicker="Product tour"
              title={
                <>
                  Everything running. <em>One calm view.</em>
                </>
              }
              description="Portly feels like part of macOS: compact, direct, and always close to the process it controls."
            />
            <a className="text-link" href={repoUrl}>
              Explore the code <ArrowRight size={15} aria-hidden="true" />
            </a>
          </div>

          <div className="screenshot-grid">
            <div className="screenshot-main">
              <ProductWindow compact />
              <div className="screenshot-caption">
                <div>
                  <span>01</span>
                  <strong>Desktop dashboard</strong>
                </div>
                <p>
                  Projects, ports, health, uptime, and terminal output stay
                  visible in one native workspace.
                </p>
              </div>
            </div>
            <div className="screenshot-stack">
              <MenuBarPreview />
              <ConflictPreview />
            </div>
          </div>
        </section>

        <section className="workflow section-pad" id="workflow">
          <SectionHeading
            kicker="How it works"
            title={
              <>
                One source of truth from <em>first prompt to final process.</em>
              </>
            }
            description="You define the server once. Humans and agents use the same controls from then on."
          />
          <div className="workflow-grid">
            <WorkflowStep
              number="01"
              icon={ListTree}
              title="Register the project"
              body="Portly detects common dev commands, frameworks, monorepos, and default ports. Confirm the server once."
              code="portly add-project --path ~/Developer/project"
            />
            <WorkflowStep
              number="02"
              icon={Code2}
              title="Let agents inspect"
              body="The CLI returns structured status, ports, health, logs, and ownership before an agent launches a process."
              code="portly status --json"
            />
            <WorkflowStep
              number="03"
              icon={Play}
              title="Reuse one process"
              body="Portly starts, supervises, restarts, and shares the same server across every task and terminal."
              code="portly start project/web --json"
            />
          </div>
        </section>

        <section className="features section-pad" id="features">
          <SectionHeading
            kicker="Built for local development"
            title={
              <>
                Small supervisor. <em>Complete runtime context.</em>
              </>
            }
            description="No cloud account, no dashboard subscription, and no process manager hidden behind an agent framework."
          />
          <div className="feature-grid">
            {features.map(({ icon: Icon, title, body }) => (
              <article className="feature-card" key={title}>
                <div className="feature-icon">
                  <Icon size={18} aria-hidden="true" />
                </div>
                <h3>{title}</h3>
                <p>{body}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="open-source section-pad" id="open-source">
          <div className="open-source-card">
            <div className="open-source-copy">
              <div className="eyebrow">
                <GithubLogo size={14} /> Open source by default
              </div>
              <h2>Read every line that can launch a process.</h2>
              <p>
                Portly is MIT licensed. Inspect the native app, the CLI, the
                loopback API, and the agent skill—or help make them better.
              </p>
              <div className="open-source-actions">
                <a className="button button-light" href={repoUrl}>
                  Star on GitHub <ExternalLink size={15} aria-hidden="true" />
                </a>
                <a
                  className="text-link text-link-light"
                  href={`${repoUrl}/blob/main/CONTRIBUTING.md`}
                >
                  Read the contribution guide{" "}
                  <ChevronRight size={15} aria-hidden="true" />
                </a>
              </div>
            </div>
            <div
              className="source-terminal"
              aria-label="Portly installation commands"
            >
              <div>
                <span className="terminal-dot" />
                <span className="terminal-dot" />
                <span className="terminal-dot" />
                <code>install.sh</code>
              </div>
              <pre>
                <span>$</span> git clone {repoUrl}.git{"\n"}
                <span>$</span> cd portly{"\n"}
                <span>$</span> ./build.sh --run{"\n"}
                {"\n"}
                <b>✓ Portly.app installed</b>
                {"\n"}
                <b>✓ portly CLI ready</b>
              </pre>
            </div>
          </div>
        </section>

        <section className="final-cta section-pad">
          <PortlyMark size={56} />
          <h2>One Mac. One server. Every agent informed.</h2>
          <p>Stop paying the process cost of missing context.</p>
          <div className="hero-actions">
            <a className="button button-primary" href={downloadUrl}>
              <Download size={17} /> Download Portly
            </a>
            <a className="button button-secondary" href={`${repoUrl}#install`}>
              <SquareTerminal size={17} /> Install from source
            </a>
          </div>
        </section>
      </main>

      <SiteFooter />
    </div>
  );
}

function SiteHeader() {
  return (
    <header className="site-header">
      <a className="brand" href="#main-content" aria-label="Portly home">
        <PortlyMark size={34} />
        <span>Portly</span>
      </a>
      <nav aria-label="Main navigation">
        <a href="#problem">Problem</a>
        <a href="#demo">Demo</a>
        <a href="#features">Features</a>
        <a href={repoUrl}>GitHub</a>
      </nav>
      <a className="header-download" href={downloadUrl}>
        Download <Download size={14} aria-hidden="true" />
      </a>
    </header>
  );
}

function SectionHeading({
  kicker,
  title,
  description,
}: {
  kicker: string;
  title: ReactNode;
  description: string;
}) {
  return (
    <div className="section-heading">
      <p className="section-kicker">{kicker}</p>
      <h2>{title}</h2>
      <p className="section-description">{description}</p>
    </div>
  );
}

function WorkflowStep({
  number,
  icon: Icon,
  title,
  body,
  code,
}: {
  number: string;
  icon: typeof ListTree;
  title: string;
  body: string;
  code: string;
}) {
  return (
    <article className="workflow-step">
      <div className="step-top">
        <span>{number}</span>
        <Icon size={19} aria-hidden="true" />
      </div>
      <h3>{title}</h3>
      <p>{body}</p>
      <code>$ {code}</code>
    </article>
  );
}

function MenuBarPreview() {
  return (
    <figure className="mini-shot menu-shot">
      <figcaption className="sr-only">
        Portly menu bar popover listing three healthy servers.
      </figcaption>
      <div className="mini-shot-surface">
        <div className="menu-title">
          <strong>Portly</strong>
          <span>3/3 running</span>
        </div>
        {[
          ["NowStack", "web", "3000"],
          ["Lumail", "workers", "3001"],
          ["Codelynx", "docs", "5173"],
        ].map(([project, server, port]) => (
          <div className="menu-server" key={project}>
            <span className="status-dot status-green" />
            <div>
              <strong>{project}</strong>
              <small>{server}</small>
            </div>
            <code>:{port}</code>
            <Square size={10} fill="currentColor" />
          </div>
        ))}
        <div className="menu-footer">
          Open Portly <ChevronRight size={12} />
        </div>
      </div>
      <div className="screenshot-caption">
        <div>
          <span>02</span>
          <strong>Menu bar control</strong>
        </div>
        <p>Check and control every server without changing windows.</p>
      </div>
    </figure>
  );
}

function ConflictPreview() {
  return (
    <figure className="mini-shot conflict-shot">
      <figcaption className="sr-only">
        Portly detects a process running outside its supervision and offers to
        take it over.
      </figcaption>
      <div className="mini-shot-surface">
        <div className="conflict-icon">!</div>
        <div className="conflict-copy">
          <strong>Running outside Portly</strong>
          <span>node (pid 91724) is using port 3000.</span>
        </div>
        <div className="conflict-actions">
          <button type="button">Stop process</button>
          <button type="button" className="conflict-primary">
            Move to Portly
          </button>
        </div>
      </div>
      <div className="screenshot-caption">
        <div>
          <span>03</span>
          <strong>Explicit port takeover</strong>
        </div>
        <p>
          See the owner first. Move it under supervision only when you choose.
        </p>
      </div>
    </figure>
  );
}

function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="footer-brand">
        <PortlyMark size={28} />
        <span>
          <strong>Portly</strong>
          <small>Local servers, under control.</small>
        </span>
      </div>
      <div className="footer-links">
        <a href={repoUrl}>Source</a>
        <a href={`${repoUrl}/releases`}>Releases</a>
        <a href={`${repoUrl}/blob/main/SECURITY.md`}>Security</a>
        <a href={`${repoUrl}/blob/main/LICENSE`}>MIT License</a>
      </div>
      <p>
        Built by <a href="https://melvynx.com">Melvynx</a>.
      </p>
    </footer>
  );
}

function GithubLogo({ size }: { size: number }) {
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
