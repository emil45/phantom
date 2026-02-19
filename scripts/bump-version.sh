#!/bin/bash
set -euo pipefail

# Bump version across all Phantom projects (Rust, iOS, macOS, build script).
# Self-validating: verifies no old version remains and new version appears
# the expected number of times. Fails loudly if anything is off.
#
# Usage:
#   ./scripts/bump-version.sh 0.6.0
#   ./scripts/bump-version.sh          # prints current version

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Read current version from source of truth ───────────────────────

current_version() {
    sed -n 's/^VERSION="${VERSION:-\([0-9]*\.[0-9]*\.[0-9]*\)}"/\1/p' "$ROOT/scripts/build-release.sh"
}

CURRENT=$(current_version)

if [ $# -eq 0 ]; then
    echo "Current version: $CURRENT"
    echo "Usage: $0 <new-version>"
    exit 0
fi

NEW="$1"

if ! echo "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: version must be semver (e.g., 0.6.0), got: $NEW"
    exit 1
fi

if [ "$NEW" = "$CURRENT" ]; then
    echo "Already at $CURRENT"
    exit 0
fi

echo "Bumping $CURRENT → $NEW"
echo ""

# ─── Targeted replacements per file type ─────────────────────────────
# Each file gets a context-aware sed pattern to avoid corrupting
# unrelated strings (e.g., pbxproj object IDs that contain digits).

CHANGED=0

replace() {
    local file="$1" pattern="$2" label="$3"
    local filepath="$ROOT/$file"

    if [ ! -f "$filepath" ]; then
        echo "  MISSING: $file"
        exit 1
    fi

    local before after
    before=$(grep -c "$CURRENT" "$filepath" 2>/dev/null || true)
    sed -i '' "$pattern" "$filepath"
    after=$(grep -c "$CURRENT" "$filepath" 2>/dev/null || true)
    local replaced=$((before - after))

    if [ "$replaced" -gt 0 ]; then
        echo "  UPDATED: $file ($label, $replaced replaced)"
        CHANGED=$((CHANGED + replaced))
    else
        echo "  SKIP:    $file (no match for pattern)"
    fi
}

# build-release.sh: VERSION="${VERSION:-X.Y.Z}"
replace "scripts/build-release.sh" \
    "s|VERSION:-$CURRENT|VERSION:-$NEW|g" \
    "VERSION default"

# Cargo.toml files: version = "X.Y.Z"
replace "daemon/phantom-daemon/Cargo.toml" \
    "s|version = \"$CURRENT\"|version = \"$NEW\"|g" \
    "package version"

replace "daemon/phantom-frame/Cargo.toml" \
    "s|version = \"$CURRENT\"|version = \"$NEW\"|g" \
    "package version"

# Info.plist: <string>X.Y.Z</string> after CFBundleShortVersionString
replace "macos/PhantomBar/Info.plist" \
    "s|<string>$CURRENT</string>|<string>$NEW</string>|g" \
    "CFBundleShortVersionString"

# Xcode pbxproj: MARKETING_VERSION = X.Y.Z;
replace "macos/PhantomBar.xcodeproj/project.pbxproj" \
    "s|MARKETING_VERSION = $CURRENT;|MARKETING_VERSION = $NEW;|g" \
    "MARKETING_VERSION"

replace "ios/Phantom.xcodeproj/project.pbxproj" \
    "s|MARKETING_VERSION = $CURRENT;|MARKETING_VERSION = $NEW;|g" \
    "MARKETING_VERSION"

# ─── Update Cargo.lock ───────────────────────────────────────────────

echo ""
echo "Updating Cargo.lock..."
(cd "$ROOT/daemon" && cargo check --quiet 2>/dev/null)

# ─── Validate ────────────────────────────────────────────────────────

echo ""
echo "Validating..."
ERRORS=0

# 1. Check each known file has zero old version in version-relevant lines
check_no_old() {
    local file="$1" pattern="$2"
    local filepath="$ROOT/$file"
    local remaining
    remaining=$(grep -c "$pattern" "$filepath" 2>/dev/null || true)
    if [ "$remaining" -gt 0 ]; then
        echo "  ERROR: $file still contains old version ($remaining lines)"
        grep -n "$pattern" "$filepath" | sed 's/^/    /'
        ERRORS=$((ERRORS + remaining))
    fi
}

check_no_old "scripts/build-release.sh"                   "VERSION:-$CURRENT"
check_no_old "daemon/phantom-daemon/Cargo.toml"           "version = \"$CURRENT\""
check_no_old "daemon/phantom-frame/Cargo.toml"            "version = \"$CURRENT\""
check_no_old "macos/PhantomBar/Info.plist"                 "<string>$CURRENT</string>"
check_no_old "macos/PhantomBar.xcodeproj/project.pbxproj" "MARKETING_VERSION = $CURRENT;"
check_no_old "ios/Phantom.xcodeproj/project.pbxproj"      "MARKETING_VERSION = $CURRENT;"

# 2. Verify expected new version count per file
check_count() {
    local file="$1" pattern="$2" expected="$3"
    local filepath="$ROOT/$file"
    local actual
    actual=$(grep -c "$pattern" "$filepath" 2>/dev/null || true)
    if [ "$actual" -ne "$expected" ]; then
        echo "  ERROR: $file has $actual occurrences of new version (expected $expected)"
        ERRORS=$((ERRORS + 1))
    fi
}

check_count "scripts/build-release.sh"                   "VERSION:-$NEW"              1
check_count "daemon/phantom-daemon/Cargo.toml"           "version = \"$NEW\""         1
check_count "daemon/phantom-frame/Cargo.toml"            "version = \"$NEW\""         1
check_count "macos/PhantomBar/Info.plist"                 "<string>$NEW</string>"      1
check_count "macos/PhantomBar.xcodeproj/project.pbxproj" "MARKETING_VERSION = $NEW;"  2
check_count "ios/Phantom.xcodeproj/project.pbxproj"      "MARKETING_VERSION = $NEW;"  2

# 3. Scan repo for version in files we might have missed
STRAY=$(grep -rn --include="*.toml" --include="*.plist" --include="*.pbxproj" \
    --include="*.sh" --include="*.json" \
    "version.*$CURRENT\|$CURRENT.*version\|MARKETING_VERSION.*$CURRENT\|VERSION:-$CURRENT" \
    "$ROOT" \
    --exclude-dir=build --exclude-dir=target --exclude-dir=.git \
    --exclude="Cargo.lock" --exclude="bump-version.sh" \
    2>/dev/null || true)

if [ -n "$STRAY" ]; then
    echo ""
    echo "  WARNING: Old version still referenced in unexpected locations:"
    echo "$STRAY" | sed 's/^/    /'
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "FAILED: $ERRORS validation errors. Check output above."
    exit 1
fi

echo "  All checks passed."
echo ""
echo "Done. $CHANGED replacements across 6 files."
echo "Version is now $NEW"
