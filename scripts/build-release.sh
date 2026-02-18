#!/bin/bash
set -euo pipefail

# Phantom release build script
# Builds a universal macOS .dmg with embedded daemon binary
#
# Environment variables:
#   VERSION          — version string (default: 0.1.0)
#   SIGNING_IDENTITY — Developer ID for codesign (empty = ad-hoc)
#   NOTARY_PROFILE   — notarytool keychain profile (empty = skip notarization)

VERSION="${VERSION:-0.1.0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
DAEMON_DIR="$PROJECT_ROOT/daemon"
MACOS_DIR="$PROJECT_ROOT/macos"
APP_NAME="Phantom"
DMG_NAME="$APP_NAME-$VERSION.dmg"

echo "==> Building Phantom $VERSION"
echo "    Signing: ${SIGNING_IDENTITY:-ad-hoc}"
echo "    Notarize: ${NOTARY_PROFILE:-skip}"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ─── Step 1: Build universal Rust daemon binary ──────────────────────

echo "==> Building Rust daemon (aarch64)..."
cd "$DAEMON_DIR"
cargo build --release --target aarch64-apple-darwin -p phantom-daemon 2>&1

echo "==> Building Rust daemon (x86_64)..."
cargo build --release --target x86_64-apple-darwin -p phantom-daemon 2>&1

echo "==> Creating universal binary..."
DAEMON_UNIVERSAL="$BUILD_DIR/phantom-daemon"
lipo -create \
    "$DAEMON_DIR/target/aarch64-apple-darwin/release/phantom" \
    "$DAEMON_DIR/target/x86_64-apple-darwin/release/phantom" \
    -output "$DAEMON_UNIVERSAL"

file "$DAEMON_UNIVERSAL"

# ─── Step 2: Build PhantomBar app ────────────────────────────────────

echo "==> Building PhantomBar..."
ARCHIVE_PATH="$BUILD_DIR/PhantomBar.xcarchive"

xcodebuild archive \
    -project "$MACOS_DIR/PhantomBar.xcodeproj" \
    -scheme PhantomBar \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY:--}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    2>&1 | tail -5

# Export the .app from the archive
APP_PATH="$BUILD_DIR/$APP_NAME.app"
cp -R "$ARCHIVE_PATH/Products/Applications/PhantomBar.app" "$APP_PATH"

# Rename to Phantom.app (user-facing name)
# The binary inside stays PhantomBar (matches Info.plist CFBundleExecutable)

echo "==> App bundle at: $APP_PATH"

# ─── Step 3: Embed daemon binary ─────────────────────────────────────

echo "==> Embedding daemon binary..."
EMBEDDED_DAEMON="$APP_PATH/Contents/MacOS/phantom-daemon"
cp "$DAEMON_UNIVERSAL" "$EMBEDDED_DAEMON"
chmod +x "$EMBEDDED_DAEMON"

# ─── Step 4: Re-sign ─────────────────────────────────────────────────

echo "==> Signing embedded binary..."
if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --timestamp --options runtime \
        --sign "$SIGNING_IDENTITY" \
        "$EMBEDDED_DAEMON"

    echo "==> Signing app bundle..."
    codesign --force --timestamp --options runtime \
        --sign "$SIGNING_IDENTITY" \
        "$APP_PATH"
else
    # Ad-hoc signing for dev builds
    codesign --force --sign - "$EMBEDDED_DAEMON"
    codesign --force --sign - "$APP_PATH"
fi

echo "==> Verifying signature..."
codesign --verify --verbose "$APP_PATH"

# ─── Step 5: Create DMG ──────────────────────────────────────────────

echo "==> Creating DMG..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_RW="$BUILD_DIR/phantom-rw.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
rm -rf "$DMG_STAGING" "$DMG_RW" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Create read-write DMG first so we can style it
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDRW \
    "$DMG_RW"

# Mount it
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_RW" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')
DISK_NAME=$(basename "$MOUNT_DIR")

# Apply Finder styling via AppleScript
echo "==> Styling DMG window (volume: $DISK_NAME)..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DISK_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 640, 400}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 80
        set background color of viewOptions to {65535, 65535, 65535}
        set position of item "$APP_NAME.app" of container window to {140, 150}
        set position of item "Applications" of container window to {400, 150}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Set hidden Finder attributes for window position on open
SetFile -a C "$MOUNT_DIR" 2>/dev/null || true

# Unmount
hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only DMG
hdiutil convert "$DMG_RW" -format UDZO -o "$DMG_PATH"
rm -f "$DMG_RW"
rm -rf "$DMG_STAGING"

echo "==> DMG created: $DMG_PATH"

# ─── Step 6: Notarize (optional) ─────────────────────────────────────

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Submitting for notarization..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "==> Stapling..."
    xcrun stapler staple "$DMG_PATH"
    echo "==> Notarization complete"
else
    echo "==> Skipping notarization (set NOTARY_PROFILE to enable)"
fi

# ─── Done ─────────────────────────────────────────────────────────────

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "==> Build complete!"
echo "    $DMG_PATH ($DMG_SIZE)"
echo "    Version: $VERSION"
