#!/usr/bin/env bash
# Build the AudioBridge HAL driver from a fresh BlackHole clone.
# Produces a signed .driver bundle and a signed installer .pkg.
#
# Requirements:
#   - Xcode + command line tools
#   - Developer ID Application certificate "GERARDO ALEMAN (D52UXTRNZA)" in keychain
#   - Developer ID Installer certificate (for signing the .pkg)
#
# Usage: ./Driver/build.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$ROOT/.driver-build"
SRC="$WORK/BlackHole"
OUT="$ROOT/Driver/build-artifacts"
DIST="$ROOT/dist"

DRIVER_NAME="AudioBridge"
BUNDLE_ID="design.publicworks.AudioBridge"
VERSION="2.2.0"
DEV_ID_APP="Developer ID Application: GERARDO ALEMAN (D52UXTRNZA)"
DEV_ID_INSTALLER="Developer ID Installer: GERARDO ALEMAN (D52UXTRNZA)"

mkdir -p "$WORK" "$OUT" "$DIST"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 https://github.com/ExistentialAudio/BlackHole "$SRC"
fi

cd "$SRC"
git apply --check "$ROOT/Driver/audiobridge-branding.patch" 2>/dev/null && \
  git apply "$ROOT/Driver/audiobridge-branding.patch" || \
  echo "Patch already applied or rejected — continuing."

xcodebuild \
  -project BlackHole.xcodeproj \
  -configuration Release \
  -target BlackHole \
  CONFIGURATION_BUILD_DIR="$WORK/build" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  PRODUCT_NAME="$DRIVER_NAME" \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) kDriver_Name=\"AudioBridge\" kPlugIn_BundleID=\"design.publicworks.AudioBridge\" kPlugIn_Manufacturer=\"PUBLIC_WORKS\"' \
  CODE_SIGN_IDENTITY="$DEV_ID_APP" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=D52UXTRNZA \
  ARCHS="x86_64 arm64" \
  ONLY_ACTIVE_ARCH=NO

rm -rf "$OUT/AudioBridge.driver"
cp -R "$WORK/build/${DRIVER_NAME}.driver" "$OUT/AudioBridge.driver"

# Build pkg
PKG_ROOT="$WORK/pkg-root"
PKG_SCRIPTS="$WORK/pkg-scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT/Library/Audio/Plug-Ins/HAL" "$PKG_SCRIPTS"
cp -R "$OUT/AudioBridge.driver" "$PKG_ROOT/Library/Audio/Plug-Ins/HAL/"

cat > "$PKG_SCRIPTS/postinstall" <<'EOF'
#!/bin/sh
set -e
chown -R root:wheel /Library/Audio/Plug-Ins/HAL/AudioBridge.driver
killall -9 coreaudiod || true
exit 0
EOF
chmod +x "$PKG_SCRIPTS/postinstall"

UNSIGNED_PKG="$DIST/AudioBridge-Driver-${VERSION}.pkg"
SIGNED_PKG="$DIST/AudioBridge-Driver-${VERSION}-signed.pkg"

pkgbuild \
  --root "$PKG_ROOT" \
  --identifier "$BUNDLE_ID.installer" \
  --version "$VERSION" \
  --scripts "$PKG_SCRIPTS" \
  --install-location "/" \
  "$UNSIGNED_PKG"

productsign \
  --sign "$DEV_ID_INSTALLER" \
  "$UNSIGNED_PKG" \
  "$SIGNED_PKG"

echo "Driver:    $OUT/AudioBridge.driver"
echo "Installer: $SIGNED_PKG"
