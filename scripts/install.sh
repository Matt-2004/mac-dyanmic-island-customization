#!/bin/zsh
# Builds Isle in Release and installs it to /Applications, then launches it.
# After the first install, re-toggle "Launch at login" in Settings so the
# login item points at /Applications/Isle.app instead of a DerivedData build.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Release -destination 'platform=macOS' build -quiet
PRODUCTS=$(xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$PRODUCTS/Isle.app"
[[ -d "$APP" ]] || { echo "Build output not found at $APP" >&2; exit 1; }

pkill -x Isle 2>/dev/null || true
sleep 0.5
rm -rf /Applications/Isle.app
ditto "$APP" /Applications/Isle.app
open /Applications/Isle.app
echo "Installed /Applications/Isle.app"
