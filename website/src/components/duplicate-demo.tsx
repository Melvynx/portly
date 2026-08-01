import { useState } from "react";

type Line = {
  agent: string;
  command: string;
  result: string;
  port: string;
  warn?: string;
  reused?: boolean;
};

const sprawl: Line[] = [
  { agent: "codex", command: "pnpm dev", result: "pid 82104", port: ":3000" },
  {
    agent: "claude",
    command: "pnpm dev",
    result: "pid 82391",
    port: ":3001",
    warn: "port 3000 in use",
  },
  {
    agent: "cursor",
    command: "pnpm dev",
    result: "pid 82618",
    port: ":3002",
    warn: "port 3001 in use",
  },
  {
    agent: "codex",
    command: "pnpm dev",
    result: "pid 82943",
    port: ":3003",
    warn: "port 3002 in use",
  },
  {
    agent: "claude",
    command: "pnpm dev",
    result: "pid 83117",
    port: ":3004",
    warn: "port 3003 in use",
  },
];

const supervised: Line[] = [
  {
    agent: "codex",
    command: "portly status --json",
    result: "pid 82104",
    port: ":3000",
    reused: true,
  },
  {
    agent: "claude",
    command: "portly status --json",
    result: "pid 82104",
    port: ":3000",
    reused: true,
  },
  {
    agent: "cursor",
    command: "portly status --json",
    result: "pid 82104",
    port: ":3000",
    reused: true,
  },
];

const modes = {
  without: {
    lines: sprawl,
    tally: "5 dev servers · 5 bundlers · 5 file watchers",
    verdict: "Four of these should not exist.",
  },
  with: {
    lines: supervised,
    tally: "1 dev server · 1 bundler · 1 file watcher",
    verdict: "Every agent read the same running process.",
  },
} as const;

export function DuplicateDemo() {
  const [mode, setMode] = useState<keyof typeof modes>("without");
  const current = modes[mode];

  return (
    <div className={`demo demo-${mode}`}>
      <div className="demo-head">
        <div className="switch" role="group" aria-label="Comparison">
          <button
            type="button"
            aria-pressed={mode === "without"}
            className={mode === "without" ? "is-active" : ""}
            onClick={() => setMode("without")}
          >
            Without Portly
          </button>
          <button
            type="button"
            aria-pressed={mode === "with"}
            className={mode === "with" ? "is-active" : ""}
            onClick={() => setMode("with")}
          >
            With Portly
          </button>
        </div>
        <p className="demo-tally" aria-live="polite">
          {current.tally}
        </p>
      </div>

      <ol className="demo-lines" key={mode}>
        {current.lines.map((line, index) => (
          <li key={`${mode}-${index}`} style={{ "--i": index } as never}>
            <span className="demo-agent">{line.agent}</span>
            <code className="demo-command">{line.command}</code>
            <span className="demo-arrow" aria-hidden="true">
              →
            </span>
            <code className="demo-pid">{line.result}</code>
            <code className={`demo-port ${line.reused ? "is-reused" : ""}`}>
              {line.port}
            </code>
            <span className="demo-warn">{line.warn ?? ""}</span>
          </li>
        ))}
      </ol>

      <p className="demo-verdict">{current.verdict}</p>
    </div>
  );
}
