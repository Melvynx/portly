# Portly

Portly is a native macOS supervisor for local development servers. It keeps each command in a real interactive PTY, checks its port, restarts it after crashes, and exposes the same controls through a menu bar app, a CLI, and a loopback-only HTTP API.

Use persistent projects for long-lived, reusable services. Use top-level **Temporary** jobs for builds, tests, one-off previews, demos, generated artifacts, and short tasks; they run in the background with a deadline, expose their logs and exit code, and are never restored on the next launch.

Portly requires macOS 14 or newer and Swift 6.

## Smart resource dashboard

The native **Resources** screen samples every Portly-owned process tree every two seconds and keeps a five-minute memory history. It shows physical footprint, resident RAM, CPU, project trends, and the current user's heaviest processes running outside Portly. Configure the optional global project limit and per-project inherit/off/custom overrides in **Settings → Memory**. A project restarts after three consecutive over-limit footprint samples, then sampling starts fresh on the replacement processes.

Portly turns those measurements into machine-aware recommendations instead of relying on one fixed limit. It detects unusually large servers and processes, sustained growth while ignoring isolated build spikes, and duplicate dev sessions outside Portly. Advice is tailored to common Next.js, Vite, Node, TypeScript, browser, Docker, Redis, and Postgres failure modes. Managed servers can be restarted or stopped from the recommendation card. External process cards show the validated stop target, parent, working directory, listening ports, and the difference between footprint and resident RAM; an explicit confirmation can send SIGTERM, but Portly never terminates them automatically or escalates to SIGKILL.

When Docker Desktop owns a published host port, Portly resolves the actual container through the Docker CLI. **Stop** and **Move to Portly** stop only that container instead of signaling the global `com.docker.backend` process.

## Install

```bash
./build.sh --run
```

This builds and ad-hoc signs `Portly.app`, installs it in `/Applications`, installs `portly` in the first writable bin directory on `PATH`, installs the bundled skill in `~/.agents/skills/portly`, adds idempotent Portly server-management rules to `~/.agents/AGENTS.md`, and launches the app. Reinstalling quits the running app first, which stops every server supervised by Portly. Public GitHub releases are signed with Developer ID and notarized by Apple.

People who download the signed macOS app can complete the same agent setup from the onboarding card at the top of Portly. It installs the bundled skill and CLI, then adds marker-delimited global rules to `~/.agents/AGENTS.md` and `~/.claude/CLAUDE.md` without replacing existing instructions.

To launch Portly automatically at every macOS login, use:

```bash
./build.sh --forever
portly forever status --json
```

`portly forever enable` preserves and restarts the servers that were active during the handoff to `launchd`. `portly forever disable` removes the LaunchAgent recoverably and leaves active servers running under a regular Portly launch. This mode supervises the macOS app; Linux requires a separate headless daemon because SwiftUI/AppKit cannot run there.

Use `./build.sh --no-install` to assemble `dist/Portly.app` without installing it.

## Updates and releases

Portly checks the signed Sparkle feed once a day and also exposes **Check for Updates…** in the app menu and Settings. The installed version is visible in Settings and in the standard About window.

To publish a new version, update the single value in `Sources/PortlyCore/Version.swift`, commit and push it, then run:

```bash
./release.sh 0.1.2
```

The release script builds a universal Apple silicon and Intel binary from the pushed commit. It creates a hardened-runtime Developer ID build, submits it to Apple for notarization, staples the ticket, signs the update with the Sparkle key stored in the macOS Keychain, and publishes `Portly-macOS.zip` plus `appcast.xml` to a versioned GitHub release. The landing page and the app feed both follow GitHub's latest release URLs.

## CLI

Every CLI command launches Portly automatically when it is closed. `status` is compact by default: it shows only active servers and problems. Use `--details` for the full human inventory and `--json` for complete machine-readable data.

```bash
portly status
portly status --details
portly status --json

portly memory-limit 5GB
portly memory-limit 3GB --project lumail.io
portly memory-limit inherit --project lumail.io
portly memory-limit off

job_id="$(portly temp 'npm run build' --timeout 20m)"
portly wait "$job_id"

portly temp 'npm run dev -- --host 127.0.0.1 --port 5180' \
  --name transcript-preview \
  --path /path/to/generated/transcript \
  --port 5180 \
  --timeout 1h

portly add-project \
  --name codelynx \
  --path ~/Developer/projects/codelynx.dev-v2 \
  --icon globe \
  --color '#0A84FF' \
  --json

portly add-server \
  --project codelynx \
  --name web \
  --command 'pnpm dev' \
  --port 5173 \
  --start \
  --json

portly logs codelynx/web --tail 100
portly restart codelynx/web --json
portly take-over codelynx/web --json
portly stop --project codelynx --json
```

Other commands are `temp` (`temporary`, `run-temp`), `wait`, `memory-limit` (`ram-limit`), `start`, `stop`, `restart`, `take-over` (`adopt`), `update-server`, `remove`, `port`, `kill-port`, `open`, `quit`, `forever`, and `config`. `temp` returns a job ID immediately; `wait` blocks for that ID and exits with the job's real exit code (`124` for timeout). `memory-limit` shows or changes the global default and project overrides; it is off by default. `take-over` stops an external listener on the configured port and relaunches the server under Portly. `forever` manages the per-user macOS LaunchAgent. Run `portly <command> --help` for exact flags. `quit` stops every managed server because the app is the supervisor.

## Configuration

Portly stores its source of truth in `~/.config/portly/config.json` and watches the file for external changes. Server logs live in `~/.config/portly/logs/`.

Temporary jobs are intentionally absent from `config.json`. They exist only in the current Portly app session, appear separately as `temporaryServers` in `portly status --json`, and retain their terminal result for one hour so an agent can wait or inspect logs after a fast command completes.

```json
{
  "version": 1,
  "apiPort": 7737,
  "healthIntervalSeconds": 10,
  "maxRestartAttempts": 5,
  "logBufferLines": 5000,
  "logFileMaxMB": 10,
  "projects": [
    {
      "id": "prj_example",
      "name": "Example",
      "icon": "globe",
      "color": "#0A84FF",
      "root": "/absolute/path/to/project",
      "servers": [
        {
          "id": "srv_example",
          "name": "web",
          "command": "pnpm dev",
          "port": 5173,
          "directory": null,
          "env": {},
          "healthURL": null,
          "healthStatus": null,
          "autoRestart": true
        }
      ]
    }
  ]
}
```

`directory` may be absolute or relative to the project root. Portly provides `PORT`, `PORTLY=1`, and `PORTLY_SERVER` to child processes. A bare port check connects to `localhost` over IPv4 or IPv6; `healthURL` may be a path such as `/api/health` or a complete URL.

## Local API

The control API listens only on `127.0.0.1:7737`. It can start processes, so it is deliberately unavailable to the network.

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/ping` | Version and availability |
| `GET` | `/status` | Projects and live server state |
| `GET` | `/config` | Current configuration |
| `GET` | `/logs?server=web&tail=200` | Recent server output |
| `GET` | `/temporary/status?id=tmp_1234` | Temporary job state, deadline and exit code |
| `GET` | `/ports?port=5173` | Process occupying a port |
| `POST` | `/start`, `/stop`, `/restart` | Act on a server or project |
| `POST` | `/temporary/run` | Start a supervised background job outside any project |
| `POST` | `/memory-limit` | Configure the global default or a project memory guard |
| `POST` | `/projects/add`, `/projects/remove` | Mutate projects |
| `POST` | `/servers/add`, `/servers/update`, `/servers/remove` | Mutate servers |
| `POST` | `/servers/take-over` | Move an external listener under Portly |
| `POST` | `/ports/kill` | Send SIGTERM to a port occupant |
| `POST` | `/open`, `/quit` | Control the app |

Responses are JSON envelopes with `ok`, `data`, and `error` fields. The CLI is the supported agent-facing interface and handles launching the app and encoding requests.

## Agent skill

The distributable skill is in [`skills/portly`](skills/portly). The installer copies it to the canonical personal root at `~/.agents/skills/portly`, which is shared by Codex and Cursor and exposed to Claude through the standard `~/.claude/skills` compatibility link.

The source installer maintains a marker-delimited rule in `~/.agents/AGENTS.md`. The downloadable app's onboarding also installs it in `~/.claude/CLAUDE.md` so Claude receives the same global fallback. During project setup, the skill requires the same rule in the repository's root `AGENTS.md`; this makes the behavior portable to collaborators and other machines. Every write is idempotent and preserves existing instructions.
