#!/bin/bash
# Builds, notarizes, and publishes the version already committed in Version.swift.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(grep -o '"[0-9][^"]*"' "$ROOT/Sources/PortlyCore/Version.swift" | tr -d '"')"
EXPECTED_VERSION="${1:-$VERSION}"
TAG="v$VERSION"

if [ "$EXPECTED_VERSION" != "$VERSION" ]; then
  echo "Version.swift contains $VERSION, not $EXPECTED_VERSION." >&2
  exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  echo "Commit the release changes before publishing $TAG." >&2
  exit 1
fi

BRANCH="$(git -C "$ROOT" branch --show-current)"
LOCAL_SHA="$(git -C "$ROOT" rev-parse HEAD)"
REMOTE_SHA="$(git -C "$ROOT" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  echo "Push $BRANCH before publishing $TAG." >&2
  exit 1
fi

if gh release view "$TAG" --repo Melvynx/portly >/dev/null 2>&1; then
  echo "Release $TAG already exists." >&2
  exit 1
fi

PREVIOUS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/portly-appcast.XXXXXX")"
trap 'trash "$PREVIOUS_DIR" >/dev/null 2>&1 || true' EXIT
gh release download --repo Melvynx/portly --pattern appcast.xml --dir "$PREVIOUS_DIR" >/dev/null 2>&1 || true

PORTLY_PREVIOUS_APPCAST="$PREVIOUS_DIR/appcast.xml" "$ROOT/build.sh" --release

gh release create "$TAG" \
  "$ROOT/dist/Portly-macOS.zip#Portly for macOS" \
  "$ROOT/dist/appcast.xml#Sparkle update feed" \
  --repo Melvynx/portly \
  --target "$LOCAL_SHA" \
  --title "Portly $VERSION" \
  --generate-notes

gh release view "$TAG" --repo Melvynx/portly --json tagName,url,assets
