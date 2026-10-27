#!/usr/bin/env bash
# Assemble build/L2 File Editor.app from the SwiftPM product L2FileEditor.
#
#   scripts/make-app.sh
#
# Environment:
#   CODESIGN_IDENTITY   signing identity (default "-": ad-hoc; a real identity also enables the hardened runtime)
#   L2ENCDEC            prebuilt l2encdec helper to bundle (default build/bin/l2encdec, built by
#                       scripts/build-l2encdec.sh when missing)
# Runnable from any cwd; prints the path of the .app on success.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/L2 File Editor.app"
CONTENTS="$APP/Contents"
PRODUCT="L2FileEditor"
RESOURCE_BUNDLE="L2FileEditor_L2FileEditorApp.bundle"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="0.1.0"

die() { echo "make-app: error: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "the app is macOS-only"

echo "make-app: swift build -c release --product $PRODUCT"
swift build --package-path "$ROOT" -c release --product "$PRODUCT"
BIN_DIR="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
[[ -x "$BIN_DIR/$PRODUCT" ]] || die "missing executable $BIN_DIR/$PRODUCT"
[[ -d "$BIN_DIR/$RESOURCE_BUNDLE" ]] || die "missing resource bundle $BIN_DIR/$RESOURCE_BUNDLE"

HELPER="${L2ENCDEC:-$ROOT/build/bin/l2encdec}"
if [[ ! -x "$HELPER" ]]; then
    [[ -z "${L2ENCDEC:-}" ]] || die "L2ENCDEC=$L2ENCDEC is not an executable file"
    echo "make-app: $HELPER missing, running scripts/build-l2encdec.sh"
    "$ROOT/scripts/build-l2encdec.sh"
    [[ -x "$HELPER" ]] || die "scripts/build-l2encdec.sh did not produce $HELPER"
fi

echo "make-app: assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers"
cp "$BIN_DIR/$PRODUCT" "$CONTENTS/MacOS/$PRODUCT"
# Bundle.module looks for the resource bundle in Bundle.main.resourceURL (Contents/Resources).
ditto "$BIN_DIR/$RESOURCE_BUNDLE" "$CONTENTS/Resources/$RESOURCE_BUNDLE"
cp "$HELPER" "$CONTENTS/Helpers/l2encdec"
chmod 755 "$CONTENTS/Helpers/l2encdec"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# App icon: the icns shared with the Tauri app (generated from gui-tauri/icons/app-icon-1024.png
# by scripts/make-tauri.sh) when present; otherwise an optional placeholder drawn with AppKit,
# scaled with sips and packed with iconutil.
ICON_KEY=""
SHARED_ICNS="$ROOT/gui-tauri/src-tauri/icons/icon.icns"
if [[ -f "$SHARED_ICNS" ]]; then
    cp "$SHARED_ICNS" "$CONTENTS/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/icon.swift" <<'SWIFT'
import AppKit
let side = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = context
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.55, green: 0.10, blue: 0.08, alpha: 1),
           ending: NSColor(calibratedRed: 0.20, green: 0.04, blue: 0.05, alpha: 1))?.draw(in: shape, angle: -90)
let title = NSAttributedString(string: "L2", attributes: [
    .font: NSFont.systemFont(ofSize: 400, weight: .heavy), .foregroundColor: NSColor(white: 0.97, alpha: 1)])
let subtitle = NSAttributedString(string: ".dat", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 150, weight: .semibold), .foregroundColor: NSColor(white: 0.85, alpha: 1)])
title.draw(at: NSPoint(x: (CGFloat(side) - title.size().width) / 2, y: 400))
subtitle.draw(at: NSPoint(x: (CGFloat(side) - subtitle.size().width) / 2, y: 210))
context.flushGraphics()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) } catch { exit(1) }
SWIFT
    if swift "$WORK/icon.swift" "$WORK/icon.png" >/dev/null 2>&1; then
        ICONSET="$WORK/AppIcon.iconset"
        mkdir -p "$ICONSET"
        for size in 16 32 128 256 512; do
            sips -z "$size" "$size" "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
            sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
        done
        if iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"; then
            ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
        fi
    fi
    [[ -n "$ICON_KEY" ]] || echo "make-app: warning: placeholder icon not generated (optional)" >&2
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>gr.blackthym.l2fileeditor</string>
    <key>CFBundleName</key><string>L2 File Editor</string>
    <key>CFBundleDisplayName</key><string>L2 File Editor</string>
    <key>CFBundleExecutable</key><string>$PRODUCT</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    $ICON_KEY
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Lineage II client file</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>dat</string>
                <string>ini</string>
                <string>int</string>
                <string>htm</string>
                <string>txt</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null

sign_options=()
[[ "$IDENTITY" == "-" ]] || sign_options=(--options runtime)
echo "make-app: codesign (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" ${sign_options[@]+"${sign_options[@]}"} "$CONTENTS/Helpers/l2encdec"
codesign --force --sign "$IDENTITY" ${sign_options[@]+"${sign_options[@]}"} "$APP"
codesign --verify --strict "$APP"

echo "make-app: OK"
echo "$APP"
