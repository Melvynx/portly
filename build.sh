#!/bin/bash
# Builds Portly.app and the portly CLI, then installs both.
#
#   ./build.sh            build + install to /Applications and /usr/local/bin
#   ./build.sh --no-install   build only, leaves the bundle in ./dist
#   ./build.sh --run          build, install, and relaunch the app
#   ./build.sh --forever      build, install, and enable launch at login

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Portly.app"
INSTALL=1
RUN=0
FOREVER=0
RUNNING_SERVERS=()

for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --run) RUN=1 ;;
    --forever) FOREVER=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Building (release)"
cd "$ROOT"
swift build -c release --product PortlyApp
swift build -c release --product portly

BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling Portly.app"
if [ -e "$APP" ]; then
  trash "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/PortlyApp" "$APP/Contents/MacOS/Portly"

# SwiftTerm ships a resource bundle; carry it along if this build produced one.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

VERSION="$(grep -o '"[0-9][^"]*"' "$ROOT/Sources/PortlyCore/Version.swift" | tr -d '"')"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Portly</string>
	<key>CFBundleDisplayName</key>
	<string>Portly</string>
	<key>CFBundleIdentifier</key>
	<string>dev.portly.app</string>
	<key>CFBundleExecutable</key>
	<string>Portly</string>
	<key>CFBundleIconFile</key>
	<string>Portly</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> Icon"
if swift "$ROOT/Tools/makeicon.swift" "$APP/Contents/Resources/Portly.icns" >/dev/null 2>&1; then
  echo "    generated"
else
  echo "    skipped (icon generation failed, using the default)"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    ad-hoc signing failed, continuing"

if [ "$INSTALL" -eq 1 ]; then
  echo "==> Installing"
  if pgrep -x Portly >/dev/null 2>&1; then
    if command -v portly >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      while IFS= read -r server_id; do
        [ -n "$server_id" ] && RUNNING_SERVERS+=("$server_id")
      done < <(portly status --json 2>/dev/null | jq -r '.projects[].servers[] | select(.state != "stopped" and .state != "failed") | .id')
    fi
    echo "    quitting the running Portly (this stops your servers)"
    if command -v portly >/dev/null 2>&1; then
      portly quit >/dev/null 2>&1 || true
    fi
    osascript -e 'quit app "Portly"' >/dev/null 2>&1 || true
    for _ in {1..20}; do
      pgrep -x Portly >/dev/null 2>&1 || break
      sleep 0.25
    done
    if pgrep -x Portly >/dev/null 2>&1; then
      echo "    Portly did not quit; close its open sheet and run the installer again" >&2
      exit 1
    fi
  fi
  if [ -e /Applications/Portly.app ]; then
    trash /Applications/Portly.app
  fi
  cp -R "$APP" /Applications/Portly.app
  echo "    /Applications/Portly.app"

  # First writable directory that is already on PATH wins.
  CLI_TARGET=""
  for candidate in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then
      CLI_TARGET="$candidate/portly"
      break
    fi
  done

  if [ -n "$CLI_TARGET" ]; then
    cp "$BIN_DIR/portly" "$CLI_TARGET"
    chmod +x "$CLI_TARGET"
    echo "    $CLI_TARGET"
  else
    echo "    no writable bin directory found, run:"
    echo "      sudo cp '$BIN_DIR/portly' /usr/local/bin/portly"
  fi

  SKILL_TARGET="$HOME/.agents/skills/portly"
  mkdir -p "$HOME/.agents/skills"
  if [ -e "$SKILL_TARGET" ] || [ -L "$SKILL_TARGET" ]; then
    trash "$SKILL_TARGET"
  fi
  cp -R "$ROOT/skills/portly" "$SKILL_TARGET"
  echo "    $SKILL_TARGET"

  AGENTS_FILE="$HOME/.agents/AGENTS.md"
  if [ ! -f "$AGENTS_FILE" ] || ! grep -Eiq 'use[^[:alnum:]]+Portly|portly:managed-rule:start' "$AGENTS_FILE"; then
    mkdir -p "$(dirname "$AGENTS_FILE")"
    if [ -s "$AGENTS_FILE" ]; then
      printf '\n' >> "$AGENTS_FILE"
    fi
    cat >> "$AGENTS_FILE" <<'RULE'
<!-- portly:managed-rule:start -->
## Development servers

- Always use Portly (`portly ...`) to start, stop, restart, inspect, or keep local development servers running.
- Start with `portly status --json`. Reuse a healthy managed server; if an in-scope server is running outside Portly, register it and use `portly take-over <project/server> --json`.
- Never launch persistent development servers directly, in the background, or through another supervisor.
<!-- portly:managed-rule:end -->
RULE
    echo "    $AGENTS_FILE (Portly rules added)"
  else
    echo "    $AGENTS_FILE (Portly rules already present)"
  fi
fi

if [ "$FOREVER" -eq 1 ]; then
  if [ "$INSTALL" -ne 1 ]; then
    echo "    --forever requires installation; remove --no-install" >&2
    exit 1
  fi
  echo "==> Enabling launch at login"
  portly forever enable
elif [ "$RUN" -eq 1 ]; then
  echo "==> Launching"
  open /Applications/Portly.app
fi

if { [ "$FOREVER" -eq 1 ] || [ "$RUN" -eq 1 ]; } && [ "${#RUNNING_SERVERS[@]}" -gt 0 ]; then
  echo "==> Restoring active servers"
  for server_id in "${RUNNING_SERVERS[@]}"; do
    portly start "$server_id" --json >/dev/null
    echo "    $server_id"
  done
fi

echo "Done."
