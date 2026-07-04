#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bundle.sh — build myterm.app (reproducible, deterministic).
#
# Steps:
#   1. Compile a release binary with SwiftPM.
#   2. Assemble the macOS .app layout:  myterm.app/Contents/{MacOS,Resources}
#   3. Write Info.plist.
#   4. Copy the shell-integration.zsh into Resources for reference.
#   5. Ad-hoc codesign (signature "-") so Gatekeeper lets us open it locally
#      without a Developer ID. Not distributable; fine for personal use.
#
# Output: ./myterm.app in the project root.
# Run:    ./bundle.sh          → build + assemble
#         ./bundle.sh --run    → also open the app when done
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_ID="io.zyp.myterm"
APP_NAME="myterm"
VERSION="0.1.0"
APP="${APP_NAME}.app"

echo "▸ compiling release binary…"
swift build -c release

echo "▸ assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "shell-integration.zsh"      "${APP}/Contents/Resources/shell-integration.zsh"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleVersion</key>               <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "▸ ad-hoc codesigning (Gatekeeper-friendly, non-distributable)…"
codesign --force --deep --sign - "${APP}" 2>&1 | sed 's/^/    /'

BIN_SIZE=$(du -sh "${APP}" | cut -f1)
echo "✓ built ${APP} (${BIN_SIZE})"
echo
echo "  Try it:"
echo "    open ./${APP}                   # launch"
echo "    cp -R ./${APP} ~/Applications/  # install for the user"

if [[ "${1:-}" == "--run" ]]; then
    open "./${APP}"
fi
