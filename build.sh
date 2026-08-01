#!/bin/bash
# Builds Portly.app and the portly CLI, then installs both.
#
#   ./build.sh            build + install to /Applications and /usr/local/bin
#   ./build.sh --no-install   build only, leaves the bundle in ./dist
#   ./build.sh --run          build, install, and relaunch the app
#   ./build.sh --forever      build, install, and enable launch at login
#   ./build.sh --release      signed + notarized ZIP and Sparkle appcast

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Portly.app"
INSTALL=1
RUN=0
FOREVER=0
RELEASE=0
RUNNING_SERVERS=()

for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --run) RUN=1 ;;
    --forever) FOREVER=1 ;;
    --release) RELEASE=1; INSTALL=0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Building (release)"
cd "$ROOT"
if [ "$RELEASE" -eq 1 ]; then
  swift build -c release --triple arm64-apple-macosx14.0 --product PortlyApp
  swift build -c release --triple x86_64-apple-macosx14.0 --product PortlyApp
  ARM64_BIN_DIR="$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)"
  X86_64_BIN_DIR="$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)"
  BIN_DIR="$ARM64_BIN_DIR"
else
  swift build -c release --product PortlyApp
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi
swift build -c release --product portly

VERSION="$(grep -o '"[0-9][^"]*"' "$ROOT/Sources/PortlyCore/Version.swift" | tr -d '"')"
SPARKLE_ACCOUNT="${PORTLY_SPARKLE_ACCOUNT:-dev.portly.app}"
SPARKLE_PUBLIC_KEY="$(tr -d '\n' < "$ROOT/Config/sparkle-public-key")"
SPARKLE_FEED_URL="https://github.com/Melvynx/portly/releases/latest/download/appcast.xml"

echo "==> Assembling Portly.app"
if [ -e "$APP" ]; then
  trash "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

if [ "$RELEASE" -eq 1 ]; then
  lipo -create "$ARM64_BIN_DIR/PortlyApp" "$X86_64_BIN_DIR/PortlyApp" -output "$APP/Contents/MacOS/Portly"
  ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Portly")"
  case " $ARCHITECTURES " in
    *" arm64 "*) ;;
    *) echo "Universal build is missing arm64: $ARCHITECTURES" >&2; exit 1 ;;
  esac
  case " $ARCHITECTURES " in
    *" x86_64 "*) ;;
    *) echo "Universal build is missing x86_64: $ARCHITECTURES" >&2; exit 1 ;;
  esac
  echo "    architectures: $ARCHITECTURES"
else
  cp "$BIN_DIR/PortlyApp" "$APP/Contents/MacOS/Portly"
fi
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/Portly"

# SwiftTerm ships a resource bundle; carry it along if this build produced one.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

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
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
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
	<key>SUFeedURL</key>
	<string>${SPARKLE_FEED_URL}</string>
	<key>SUPublicEDKey</key>
	<string>${SPARKLE_PUBLIC_KEY}</string>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
</dict>
</plist>
PLIST

echo "==> Icon"
if swift "$ROOT/Tools/makeicon.swift" "$APP/Contents/Resources/Portly.icns" >/dev/null 2>&1; then
  echo "    generated"
else
  echo "    skipped (icon generation failed, using the default)"
fi

if [ "$RELEASE" -eq 1 ]; then
  SIGN_IDENTITY="${PORTLY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "No Developer ID Application identity is available in the keychain." >&2
    exit 1
  fi
  echo "==> Signing for Developer ID distribution"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"

  ARCHIVE="$DIST/Portly-macOS.zip"
  if [ -e "$ARCHIVE" ]; then
    trash "$ARCHIVE"
  fi
  echo "==> Archiving"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

  echo "==> Notarizing with Apple"
  asc notarization submit --file "$ARCHIVE" --wait --timeout 1h --output table
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"

  # The final archive contains the stapled ticket, so it works even when the
  # first launch cannot reach Apple's notarization service.
  trash "$ARCHIVE"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
  spctl --assess --type execute --verbose=2 "$APP"

  echo "==> Generating Sparkle appcast"
  UPDATE_DIR="$DIST/update"
  if [ -e "$UPDATE_DIR" ]; then
    trash "$UPDATE_DIR"
  fi
  mkdir -p "$UPDATE_DIR"
  cp "$ARCHIVE" "$UPDATE_DIR/"
  if [ -n "${PORTLY_PREVIOUS_APPCAST:-}" ] && [ -f "$PORTLY_PREVIOUS_APPCAST" ]; then
    cp "$PORTLY_PREVIOUS_APPCAST" "$UPDATE_DIR/appcast.xml"
  fi
  GENERATE_APPCAST="${PORTLY_GENERATE_APPCAST:-}"
  if [ -z "$GENERATE_APPCAST" ]; then
    GENERATE_APPCAST="$(find "$ROOT/.build/artifacts" -type f -name generate_appcast -print -quit)"
  fi
  if [ -z "$GENERATE_APPCAST" ] || [ ! -x "$GENERATE_APPCAST" ]; then
    echo "Sparkle's generate_appcast tool was not found." >&2
    exit 1
  fi
  "$GENERATE_APPCAST" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/Melvynx/portly/releases/download/v${VERSION}/" \
    --link "https://portly.melvynx.dev" \
    "$UPDATE_DIR"
  cp "$UPDATE_DIR/appcast.xml" "$DIST/appcast.xml"
  echo "    $ARCHIVE"
  echo "    $DIST/appcast.xml"
else
  echo "==> Signing (ad-hoc)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    ad-hoc signing failed, continuing"
fi

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
