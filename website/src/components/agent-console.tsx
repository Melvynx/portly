import { useState } from "react";
import type { KeyboardEvent, ReactNode } from "react";

type Step = {
  id: string;
  tab: string;
  note: string;
  command: string;
  output: string;
  lang: "json" | "text";
};

const steps: Step[] = [
  {
    id: "inspect",
    tab: "Inspect",
    note: "Before anything is launched, the agent reads live state.",
    command: "portly status --json",
    lang: "json",
    output: `{
  "apiPort" : 7737,
  "projects" : [
    {
      "color" : "#0A84FF",
      "icon" : "shippingbox.fill",
      "id" : "prj_62bafa3d",
      "name" : "NowStack",
      "root" : "/Users/you/Developer/nowstack",
      "servers" : [
        {
          "command" : "pnpm dev",
          "healthy" : true,
          "id" : "srv_db263513",
          "name" : "web",
          "pid" : 82104,
          "port" : 3000,
          "restartCount" : 0,
          "startedAt" : "2026-08-01T06:44:52Z",
          "state" : "running",
          "url" : "http://localhost:3000"
        }
      ]
    }
  ],
  "version" : "0.1.0"
}`,
  },
  {
    id: "register",
    tab: "Register",
    note: "A server is declared once. The command, port, and health check are stored, not repeated.",
    command:
      "portly add-server --project nowstack --name web \\\n  --command 'pnpm dev' --port 3000 --start --json",
    lang: "json",
    output: `{
  "affected" : [
    "srv_db263513"
  ],
  "message" : "add server web to NowStack"
}`,
  },
  {
    id: "conflict",
    tab: "Resolve",
    note: "A busy port is a question, not a kill. Portly names the occupant first.",
    command: "portly port 3000 --json",
    lang: "json",
    output: `{
  "occupant" : {
    "command" : "node",
    "ownedByPortly" : false,
    "pid" : 91724,
    "port" : 3000,
    "serverID" : null,
    "user" : "you"
  },
  "port" : 3000
}`,
  },
  {
    id: "logs",
    tab: "Read",
    note: "Captured output survives the terminal tab that started it.",
    command: "portly logs nowstack/web --tail 6",
    lang: "text",
    output: `➜  Local:   http://localhost:3000/
➜  Network: use --host to expose
✓ ready in 438 ms
portly health check 200 OK (tcp :3000)
portly state published on 127.0.0.1:7737
portly log file ~/.config/portly/logs/srv_db263513.log`,
  },
];

const JSON_TOKENS =
  /("(?:[^"\\]|\\.)*"\s*:)|("(?:[^"\\]|\\.)*")|(-?\d+(?:\.\d+)?)|(true|false|null)/g;

function highlightJson(line: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  let cursor = 0;
  let match: RegExpExecArray | null;
  JSON_TOKENS.lastIndex = 0;

  while ((match = JSON_TOKENS.exec(line)) !== null) {
    if (match.index > cursor) nodes.push(line.slice(cursor, match.index));
    const [token, key, string, number, literal] = match;
    const cls = key ? "j-key" : string ? "j-str" : number ? "j-num" : "j-lit";
    nodes.push(
      <span className={cls} key={`${match.index}-${token}`}>
        {token}
      </span>,
    );
    cursor = match.index + token.length;
    void literal;
  }

  if (cursor < line.length) nodes.push(line.slice(cursor));
  return nodes;
}

function highlightText(line: string): ReactNode {
  if (line.startsWith("portly")) {
    return (
      <>
        <span className="t-tag">portly</span>
        {line.slice(6)}
      </>
    );
  }
  if (line.startsWith("✓")) {
    return (
      <>
        <span className="t-green">✓</span>
        {line.slice(1)}
      </>
    );
  }
  if (line.startsWith("➜")) {
    return (
      <>
        <span className="t-green">➜</span>
        {line.slice(1)}
      </>
    );
  }
  return line;
}

export function AgentConsole() {
  const [active, setActive] = useState(steps[0].id);
  const step = steps.find((item) => item.id === active) ?? steps[0];

  /*
   * Tabs move with the arrow keys and the strip holds a single tab stop, so
   * Tab reaches the panel instead of walking through all four commands.
   */
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const offset =
      event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
    const index = steps.findIndex((item) => item.id === active);
    let next = -1;

    if (offset !== 0) next = (index + offset + steps.length) % steps.length;
    if (event.key === "Home") next = 0;
    if (event.key === "End") next = steps.length - 1;
    if (next === -1) return;

    event.preventDefault();
    setActive(steps[next].id);
    document.getElementById(`tab-${steps[next].id}`)?.focus();
  };

  return (
    <div className="console">
      <div className="console-tabs">
        <div
          className="console-tablist"
          role="tablist"
          aria-label="Agent commands"
          onKeyDown={onKeyDown}
        >
          {steps.map((item) => (
            <button
              type="button"
              key={item.id}
              role="tab"
              id={`tab-${item.id}`}
              aria-selected={item.id === active}
              aria-controls={`panel-${item.id}`}
              tabIndex={item.id === active ? 0 : -1}
              className={item.id === active ? "is-active" : ""}
              onClick={() => setActive(item.id)}
            >
              {item.tab}
            </button>
          ))}
        </div>
        <span className="console-endpoint">127.0.0.1:7737</span>
      </div>

      <div
        className="console-body"
        role="tabpanel"
        id={`panel-${step.id}`}
        aria-labelledby={`tab-${step.id}`}
      >
        <p className="console-note">{step.note}</p>
        <pre className="console-command">
          {step.command.split("\n").map((line, index) => (
            <span key={`${step.id}-cmd-${index}`}>
              {index === 0 ? <b>$</b> : <b> </b>} {line}
              {"\n"}
            </span>
          ))}
        </pre>
        <pre className="console-output">
          {step.output.split("\n").map((line, index) => (
            <span key={`${step.id}-out-${index}`}>
              {step.lang === "json" ? highlightJson(line) : highlightText(line)}
              {"\n"}
            </span>
          ))}
        </pre>
      </div>
    </div>
  );
}
