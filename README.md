# Portly

Portly is a native macOS supervisor for local development servers. It keeps each command in a real interactive PTY, checks its port, restarts it after crashes, and exposes the same controls through a menu bar app, a CLI, and a loopback-only HTTP API.

Portly requires macOS 14 or newer and Swift 6.

## Install

```bash
./build.sh --run
```

This builds and ad-hoc signs `Portly.app`, installs it in `/Applications`, installs `portly` in the first writable bin directory on `PATH`, and launches the app. Reinstalling quits the running app first, which stops every server supervised by Portly.

Use `./build.sh --no-install` to assemble `dist/Portly.app` without installing it.

## CLI

Every CLI command launches Portly automatically when it is closed. Prefer `--json` for scripts and agents.

```bash
portly status --json

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
portly stop --project codelynx --json
```

Other commands are `start`, `stop`, `restart`, `update-server`, `remove`, `port`, `kill-port`, `open`, `quit`, and `config`. Run `portly <command> --help` for exact flags. `quit` stops every managed server because the app is the supervisor.

## Configuration

Portly stores its source of truth in `~/.config/portly/config.json` and watches the file for external changes. Server logs live in `~/.config/portly/logs/`.

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
| `GET` | `/ports?port=5173` | Process occupying a port |
| `POST` | `/start`, `/stop`, `/restart` | Act on a server or project |
| `POST` | `/projects/add`, `/projects/remove` | Mutate projects |
| `POST` | `/servers/add`, `/servers/update`, `/servers/remove` | Mutate servers |
| `POST` | `/ports/kill` | Send SIGTERM to a port occupant |
| `POST` | `/open`, `/quit` | Control the app |

Responses are JSON envelopes with `ok`, `data`, and `error` fields. The CLI is the supported agent-facing interface and handles launching the app and encoding requests.

## Agent skill

The distributable skill is in [`skills/portly`](skills/portly). Copy that folder into an agent's skill directory, or use the workspace copy at `~/cc/.agents/skills/portly`.
