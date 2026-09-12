#!/usr/bin/env bash
# Build the GAMMA Configurator SwiftUI app bundle. Source lives in
# runtime/configurator-gui/Sources/*.swift; mirrors gamma-setup-tool/build.sh's
# swiftc-direct, no-Xcode packaging approach. Invoked by pack-engine-artifact.sh
# so the built Configurator.app ships prebuilt inside the engine artifact
# (share/gamma/Configurator.app); interactive-setup.sh just copies it per-install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_APP="${1:?Usage: build-configurator.sh <output .app path>}"
CONTENTS_DIR="$OUT_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BINARY="$MACOS_DIR/Configurator"

rm -rf "$OUT_APP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI \
  -framework AppKit \
  "$REPO_ROOT"/runtime/configurator-gui/Sources/*.swift \
  -o "$BINARY"
chmod +x "$BINARY"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Configurator</string>
  <key>CFBundleIdentifier</key>
  <string>com.gamma.wine-engine.configurator</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>GAMMA Configurator</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "==> Built $OUT_APP"
