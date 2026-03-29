#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/.build"
APP_NAME="Notchy"
INSTALL_PATH="/Applications/$APP_NAME.app"

echo "Building $APP_NAME..."
xcodebuild \
  -project Notchy.xcodeproj \
  -scheme Notchy \
  -configuration Debug \
  -derivedDataPath "$BUILD_DIR" \
  build \
  2>&1 | tail -5

BUILT_APP="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"

if [ ! -d "$BUILT_APP" ]; then
  echo "ERROR: Build failed - $APP_NAME.app not found at $BUILT_APP"
  exit 1
fi

echo "Build succeeded."

# Kill running instance
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
  echo "Stopping running $APP_NAME..."
  killall "$APP_NAME" 2>/dev/null || true
  sleep 1
fi

# Install
echo "Installing to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$BUILT_APP" "$INSTALL_PATH"

# Launch
echo "Launching $APP_NAME..."
open "$INSTALL_PATH"

echo "Done."
