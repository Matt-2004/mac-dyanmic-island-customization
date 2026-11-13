#!/bin/zsh
# Builds Isle in Release, installs it to /Applications and (re)starts it as a
# background service (launchd agent com.wai.Isle.agent: starts at login,
# restarts after a crash). The first launch registers the service by itself.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.wai.Isle.agent"
DOMAIN="gui/$(id -u)"
DEST="/Applications/Isle.app"

xcodegen generate --quiet
xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Release -destination 'platform=macOS' build -quiet
PRODUCTS=$(xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$PRODUCTS/Isle.app"
[[ -d "$APP" ]] || { echo "Build output not found at $APP" >&2; exit 1; }

# Swap the bundle in one step so launchd never relaunches a half-copied app.
rm -rf "$DEST.new"
ditto "$APP" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  # Service already registered: restart it on the new binary.
  launchctl kickstart -k "$DOMAIN/$LABEL"
  echo "Installed $DEST and restarted the background service."
else
  # First install: launching the app registers the service, which then takes over.
  open "$DEST"
  echo "Installed $DEST. It registers itself as a background service on first launch."
fi
