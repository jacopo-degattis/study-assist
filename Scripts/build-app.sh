#!/usr/bin/env bash
# Builds the StudyApp binary and assembles a runnable .app bundle in dist/.
# Ad-hoc signing is enough for local use; replace with a Developer ID identity
# for distribution (and notarize).
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building StudyApp ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product StudyApp
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP="$ROOT/dist/StudyApp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/StudyApp" "$APP/Contents/MacOS/StudyApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Swift Package resource bundles (AGENT.md and future resources).
shopt -s nullglob
for bundle in "$BIN_PATH"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# A visible copy of the default instructions for inspection.
cp "$ROOT/Sources/StudyPrompts/Resources/AGENT.md" "$APP/Contents/Resources/AGENT.md"

# Local ad-hoc signature so the microphone and speech permission prompts work.
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $APP"
echo "Run with: open \"$APP\""
