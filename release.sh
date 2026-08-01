#!/bin/bash
# Builds, notarizes, and publishes the version already committed in Version.swift.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(git -C "$ROOT" show HEAD:Sources/PortlyCore/Version.swift | grep -o '"[0-9][^"]*"' | tr -d '"')"
EXPECTED_VERSION="${1:-$VERSION}"
TAG="v$VERSION"

if [ "$EXPECTED_VERSION" != "$VERSION" ]; then
  echo "Version.swift contains $VERSION, not $EXPECTED_VERSION." >&2
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

RELEASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/portly-release.XXXXXX")"
SOURCE_DIR="$RELEASE_DIR/source"
PREVIOUS_DIR="$RELEASE_DIR/previous"
mkdir -p "$SOURCE_DIR" "$PREVIOUS_DIR"
trap 'trash "$RELEASE_DIR" >/dev/null 2>&1 || true' EXIT

# Build exactly the pushed commit. Local edits in the working tree are never
# stashed, copied into the archive, or otherwise disturbed.
git -C "$ROOT" archive HEAD | tar -x -C "$SOURCE_DIR"
gh release download --repo Melvynx/portly --pattern appcast.xml --dir "$PREVIOUS_DIR" >/dev/null 2>&1 || true

PORTLY_PREVIOUS_APPCAST="$PREVIOUS_DIR/appcast.xml" "$SOURCE_DIR/build.sh" --release

gh release create "$TAG" \
  "$SOURCE_DIR/dist/Portly-macOS.zip#Portly for macOS" \
  "$SOURCE_DIR/dist/appcast.xml#Sparkle update feed" \
  --repo Melvynx/portly \
  --target "$LOCAL_SHA" \
  --title "Portly $VERSION" \
  --generate-notes

mkdir -p "$ROOT/dist"
cp "$SOURCE_DIR/dist/Portly-macOS.zip" "$ROOT/dist/Portly-macOS.zip"
cp "$SOURCE_DIR/dist/appcast.xml" "$ROOT/dist/appcast.xml"

gh release view "$TAG" --repo Melvynx/portly --json tagName,url,assets
