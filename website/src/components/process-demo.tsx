import { ArrowRight, Check, CircleStop, Sparkles } from "lucide-react";
import type { CSSProperties } from "react";
import { useState } from "react";

const duplicateJobs = [
  { agent: "Codex · task 01", pid: "82104", port: "3000", state: "running" },
  { agent: "Claude · task 12", pid: "82391", port: "3001", state: "duplicate" },
  { agent: "Cursor · task 07", pid: "82618", port: "3002", state: "duplicate" },
  { agent: "Codex · task 18", pid: "82943", port: "3003", state: "duplicate" },
  { agent: "Claude · task 21", pid: "83117", port: "3004", state: "duplicate" },
];

export function ProcessDemo() {
  const [mode, setMode] = useState<"without" | "with">("without");

  return (
    <div className="demo-shell" aria-label="Interactive process comparison">
      <div className="demo-toolbar">
        <div
          className="segmented-control"
          aria-label="Choose a comparison"
          role="group"
        >
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
        <span
          className={`demo-summary ${mode === "with" ? "is-healthy" : ""}`}
          aria-live="polite"
        >
          {mode === "with" ? "1 supervised process" : "5 duplicate processes"}
        </span>
      </div>

      <div className="demo-content">
        <div className="demo-agents" aria-hidden="true">
          <span>CODEX</span>
          <span>CLAUDE</span>
          <span>CURSOR</span>
        </div>

        {mode === "without" ? (
          <div className="process-list process-list-chaos" key="without">
            {duplicateJobs.map((job, index) => (
              <div
                className="process-row"
                key={job.agent}
                style={{ "--row-index": index } as CSSProperties}
              >
                <span
                  className={
                    index === 0
                      ? "status-dot status-green"
                      : "status-dot status-orange"
                  }
                />
                <div>
                  <strong>{job.agent}</strong>
                  <span>pnpm dev</span>
                </div>
                <code>PID {job.pid}</code>
                <code>:{job.port}</code>
              </div>
            ))}
          </div>
        ) : (
          <div className="process-resolved" key="with">
            <div className="agent-request">
              <Sparkles size={16} aria-hidden="true" />
              <span>Agent asks Portly for live server state</span>
            </div>
            <ArrowRight
              className="resolution-arrow"
              size={20}
              aria-hidden="true"
            />
            <div className="process-row process-row-primary">
              <span className="status-dot status-green" />
              <div>
                <strong>nowstack / web</strong>
                <span>Healthy · supervised by Portly</span>
              </div>
              <code>PID 82104</code>
              <code>:3000</code>
            </div>
            <div className="resolved-note">
              <Check size={16} aria-hidden="true" />
              <span>
                Every agent reuses the same process, port, logs, and health
                state.
              </span>
            </div>
          </div>
        )}
      </div>

      <div className="demo-footer">
        <CircleStop size={15} aria-hidden="true" />
        <span>
          {mode === "with"
            ? "4 unnecessary launches prevented"
            : "4 processes should not exist"}
        </span>
      </div>
    </div>
  );
}
