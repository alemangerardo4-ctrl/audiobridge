#!/usr/bin/env bash
# Build, bundle, and codesign the AudioBridge menu bar app as a universal
# (arm64 + x86_64) macOS app. Works with just Command Line Tools (no full Xcode).
#
# Output: dist/AudioBridge-<version>.zip
#
# This repo lives in an iCloud-synced path, which sticks com.apple.FinderInfo
# and com.apple.fileprovider xattrs onto every directory. Those xattrs make
# `codesign` reject the bundle. We work around it by staging the bundle in
# /tmp (which is not synced) for the lipo + sign step, then ditto the result
# into a zip in dist/. We never leave a signed .app at the worktree root.
#
# After signing, notarize separately if you need Gatekeeper acceptance:
#   xcrun notarytool submit dist/AudioBridge-2.2.0.zip --keychain-profile <profile> --wait
#   ditto -xk dist/AudioBridge-2.2.0.zip /tmp/staple
#   xcrun stapler staple /tmp/staple/AudioBridge.app

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

DEV_ID="Developer ID Application: GERARDO ALEMAN (D52UXTRNZA)"
APP="AudioBridge.app"
BIN="AudioBridgeApp"
VERSION="2.2.3"

# Read version from Info.plist if available, falling back to the constant above.
if PLIST_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AudioBridgeApp/Info.plist 2>/dev/null)"; then
  VERSION="$PLIST_VER"
fi

# 1. Compile both architectures inside the iCloud path (object/binary files
#    are rebuilt every time, so transient xattrs don't matter here).
rm -rf .build/arm64 .build/x86_64
mkdir -p .build/arm64 .build/x86_64

swiftc -O -target arm64-apple-macos13  -o .build/arm64/$BIN  \
  -framework Cocoa -framework CoreAudio -framework UserNotifications \
  AudioBridgeApp/main.swift

swiftc -O -target x86_64-apple-macos13 -o .build/x86_64/$BIN \
  -framework Cocoa -framework CoreAudio -framework UserNotifications \
  AudioBridgeApp/main.swift

# 2. Stage the bundle in /tmp (xattr-clean), lipo, sign, verify.
STAGE="$(mktemp -d /tmp/audiobridge-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$APP/Contents/MacOS" "$STAGE/$APP/Contents/Resources"

lipo -create -output "$STAGE/$APP/Contents/MacOS/$BIN" \
  .build/arm64/$BIN .build/x86_64/$BIN

cp AudioBridgeApp/Info.plist "$STAGE/$APP/Contents/Info.plist"

if [ -f AudioBridgeApp/Resources/AppIcon.icns ]; then
  cp AudioBridgeApp/Resources/AppIcon.icns "$STAGE/$APP/Contents/Resources/AppIcon.icns"
fi

xattr -cr "$STAGE/$APP"
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$STAGE/$APP"
codesign --verify --strict --verbose=2 "$STAGE/$APP"

# 3. Zip the signed bundle straight into dist/.
mkdir -p dist
ZIP="dist/AudioBridge-${VERSION}.zip"
rm -f "$ZIP"
( cd "$STAGE" && ditto -ck --norsrc --noextattr --noacl --keepParent "$APP" "$HERE/$ZIP" )

echo
echo "Built: $HERE/$ZIP ($(du -h "$ZIP" | cut -f1))"
echo
codesign -dvv "$STAGE/$APP" 2>&1 | head -10

# 4. Optional: drop a fresh copy at the worktree root for local testing.
#    The signature WILL pick up FinderInfo from iCloud sync — verify will fail
#    even though the binary itself is unchanged. Run from the zip or from a
#    /tmp extraction for a clean test.
if [ "${1:-}" = "--also-extract" ]; then
  echo
  echo "Extracting clean copy to /tmp/AudioBridge-test/AudioBridge.app for testing"
  rm -rf /tmp/AudioBridge-test
  mkdir -p /tmp/AudioBridge-test
  ditto -xk "$ZIP" /tmp/AudioBridge-test
  echo "Run with:  open /tmp/AudioBridge-test/AudioBridge.app"
fi
