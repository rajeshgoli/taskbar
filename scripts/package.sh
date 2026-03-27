#!/bin/bash
set -euo pipefail

APP_NAME="DeskBar"
BUILD_DIR=".build/release"
BUNDLE_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Clean previous bundle
rm -rf "$BUNDLE_DIR"

# Create bundle structure
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"

# Generate Info.plist from template
sed "s|__EXECUTABLE__|$APP_NAME|g" Info.plist.template > "$CONTENTS_DIR/Info.plist"

# Ad-hoc codesign
codesign --force --sign - "$BUNDLE_DIR"

echo "Bundle created: $BUNDLE_DIR"
echo "To run: open $BUNDLE_DIR"
