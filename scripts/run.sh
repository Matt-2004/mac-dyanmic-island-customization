#!/bin/zsh
# Regenerates the Xcode project, builds Debug, and (re)launches Isle.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug -destination 'platform=macOS' build -quiet
APP_DIR=$(xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')
pkill -x Isle 2>/dev/null || true
open "$APP_DIR/Isle.app"
echo "Launched $APP_DIR/Isle.app"
