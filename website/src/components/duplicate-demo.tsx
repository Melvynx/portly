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
    verdict: "Every agent reads the same running process.",
  },
} as const;

export function DuplicateDemo() {
  const [mode, setMode] = useState<keyof typeof modes>("without");
  const current = modes[mode];

  return (
    /* "rows" reveals the table by printing its rows, rather than sliding the
       whole block in and then trickling the rows in on top of it.
       The mode rides on a data attribute, not on className: the observer adds
       .is-in to this same node, and a re-rendered className would wipe it. */
    <div className="demo" data-mode={mode} data-reveal="rows">
      <div className="demo-head">
        <div className="switch" role="group" aria-label="Comparison">
          {/* One thumb that slides, so the two states read as one control. */}
          <span className="switch-thumb" aria-hidden="true" />
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
        {/* The live region itself stays mounted so it keeps announcing; only
            the text inside is swapped, which is what crossfades. */}
        <p className="demo-tally" aria-live="polite">
          <span key={mode}>{current.tally}</span>
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

      <p className="demo-verdict" key={`verdict-${mode}`}>
        {current.verdict}
      </p>
    </div>
  );
}
