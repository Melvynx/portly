---
name: portly
description: Manage persistent local development servers with the Portly macOS app and CLI. Use whenever an agent would otherwise launch a long-lived dev server or needs to inspect logs and state, register or configure projects and commands, start, stop, restart, or adopt servers, resolve local port conflicts, open Portly, or safely quit the supervisor.
---

# Portly

Use the `portly` CLI as the primary interface. Every command launches Portly.app automatically if needed; this is a state-changing side effect even for `status` when the app was closed.

## Inspect first

Run `portly status --json`. Use an exact server ID or `project/server` when names are ambiguous. Prefer `--json` whenever supported.

## Command reference

| Command | Purpose |
| --- | --- |
| `status`, `list`, `ls` | List projects and live server state |
| `start`, `stop`, `restart` | Control a server or every server in `--project` |
| `logs` | Read captured output with `--tail` |
| `add-project`, `add-server`, `update-server`, `remove` | Manage configuration |
| `take-over`, `adopt` | Move an external listener under Portly |
| `port`, `kill-port` | Inspect or explicitly stop a port occupant |
| `open`, `quit`, `config` | Control the app or read its configuration |

Run `portly <command> --help` for exact flags. Prefer `--json`; `config` prints JSON or a path directly.

## Add and verify a server

1. Confirm the project path and dev command from the repository.
2. Register the project only if absent.
3. Check the intended port with `portly port <port> --json`.
4. Add it with `portly add-server --project <project> --name <name> --command '<command>' --port <port> --start --json`.
5. Poll `portly status --json` until `running` and `healthy`.
6. Verify the meaningful URL and inspect `portly logs <project/server> --tail 100 --json`.

Register projects with `portly add-project --name <name> --path <absolute-path> --icon <sf-symbol> --color '<hex>' --json`.

Portly injects `PORT`, `PORTLY=1`, and `PORTLY_SERVER`. The configured port drives health checks; a process that does not listen there will not become healthy.

## Operate and diagnose

Use `start`, `stop`, or `restart` with a server, or `--project <project>`. `portly stop --all --json` stops everything. Use `update-server` to change fields, then restart a running server.

Inspect conflicts with `portly port <port> --json`. Use `portly kill-port <port> --json` only when the kill is requested or the occupant is confirmed in scope. Portly sends SIGTERM and never auto-kills conflicts.

When a configured server's port is held by a process launched elsewhere, use `portly take-over <project/server> --json` (alias: `adopt`). Portly sends SIGTERM, waits for the port to be released, then starts the configured command itself. Never take over an unknown process without confirming it is in scope.

Keep proof distinct: `status` proves Portly state, `logs` proves captured child output, `port` proves a listener, and `curl` proves the meaningful route responds.

## Remove, quit, and configure

- Remove a server: `portly remove <project/server> --json`.
- Remove a project: `portly remove --project <project> --json`.
- Show config: `portly config` or `portly config --path-only`.
- Open the app: `portly open --json`.
- Quit: `portly quit --json`.

Removing a project stops its servers. Quitting stops every managed server because Portly is the supervisor. The source of truth is `~/.config/portly/config.json`, hot-reloaded by the app; logs are in `~/.config/portly/logs/`.
