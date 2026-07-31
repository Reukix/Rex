#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/Dist"
APP_PATH="${1:-$DIST_DIR/Rex.app}"
EXPECTED_VERSION="${2:-0.9.5}"
EXPECTED_BUILD="${3:-952}"
CHANNEL="${4:-prerelease}"

if [[ ! "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be a stable SemVer value without a leading v." >&2
  exit 8
fi
if [[ ! "$EXPECTED_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Build number must contain decimal digits only." >&2
  exit 8
fi
if [[ "$CHANNEL" != "prerelease" ]]; then
  echo "This script only creates explicitly labeled prerelease media." >&2
  exit 8
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "Rex.app is missing: $APP_PATH" >&2
  exit 5
fi
if ! command -v hdiutil >/dev/null 2>&1; then
  echo "hdiutil is required to create a macOS disk image." >&2
  exit 7
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" || "$ACTUAL_BUILD" != "$EXPECTED_BUILD" ]]; then
  echo "Rex.app version mismatch: expected $EXPECTED_VERSION/$EXPECTED_BUILD, received $ACTUAL_VERSION/$ACTUAL_BUILD." >&2
  exit 9
fi

DMG_NAME="Rex-v${EXPECTED_VERSION}-build${EXPECTED_BUILD}-macos-arm64-prerelease.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
DMG_TEMP="$DIST_DIR/.${DMG_NAME}.tmp-$$.dmg"
VOLUME_NAME="Rex ${EXPECTED_VERSION} Pre-release"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rex-dmg-stage.XXXXXX")"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rex-dmg-mount.XXXXXX")"
ATTACHED_DEVICE=""

cleanup() {
  if [[ -n "$ATTACHED_DEVICE" ]]; then
    /usr/bin/hdiutil detach "$ATTACHED_DEVICE" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$STAGING_DIR" "$MOUNT_DIR"
  /bin/rm -f "$DMG_TEMP"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

verify_arm64() {
  local app_path="$1"
  local architectures
  architectures="$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/Rex")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Rex must be arm64-only; received: $architectures" >&2
    exit 6
  fi
}

verify_bundle() {
  local app_path="$1"
  local info_plist="$app_path/Contents/Info.plist"
  local version
  local build

  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
  if [[ "$version" != "$EXPECTED_VERSION" || "$build" != "$EXPECTED_BUILD" ]]; then
    echo "Mounted Rex.app version mismatch: expected $EXPECTED_VERSION/$EXPECTED_BUILD, received $version/$build." >&2
    exit 9
  fi
  verify_arm64 "$app_path"
  /usr/bin/codesign --verify --deep --strict --verbose=4 "$app_path"
}

echo "==> Verifying source Rex.app"
verify_bundle "$APP_PATH"

echo "==> Preparing pre-release disk image contents"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/Rex.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
{
  echo "Rex v${EXPECTED_VERSION} build ${EXPECTED_BUILD} pre-release"
  echo
  echo "This build is for testing only."
  echo "It uses an ad-hoc signature, has Hardened Runtime disabled, and is not notarized."
  echo "Drag Rex.app to Applications to install it."
  echo
  echo "Architecture: Apple Silicon arm64"
  echo "Chromium: 150.0.7871.129"
  echo "CEF: 150.0.14"
} > "$STAGING_DIR/PRE-RELEASE.txt"

echo "==> Creating compressed DMG"
/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_TEMP"

echo "==> Verifying disk image structure"
/usr/bin/hdiutil verify "$DMG_TEMP"
ATTACH_OUTPUT="$(/usr/bin/hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_DIR" \
  "$DMG_TEMP")"
ATTACHED_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | /usr/bin/awk '/^\/dev\// {print $1; exit}')"
if [[ -z "$ATTACHED_DEVICE" ]]; then
  echo "Unable to determine the mounted DMG device." >&2
  exit 12
fi

test -d "$MOUNT_DIR/Rex.app"
test -L "$MOUNT_DIR/Applications"
test -f "$MOUNT_DIR/PRE-RELEASE.txt"
verify_bundle "$MOUNT_DIR/Rex.app"

/usr/bin/hdiutil detach "$ATTACHED_DEVICE" >/dev/null
ATTACHED_DEVICE=""

/bin/mv -f "$DMG_TEMP" "$DMG_PATH"
DMG_SHA="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
CHECKSUMS_TEMP="$STAGING_DIR/SHA256SUMS"
if [[ -f "$DIST_DIR/SHA256SUMS" ]]; then
  /usr/bin/awk -v name="$DMG_NAME" '$2 != name {print}' \
    "$DIST_DIR/SHA256SUMS" > "$CHECKSUMS_TEMP"
fi
echo "$DMG_SHA  $DMG_NAME" >> "$CHECKSUMS_TEMP"
/bin/mv -f "$CHECKSUMS_TEMP" "$DIST_DIR/SHA256SUMS"

{
  echo "product=Rex.app"
  echo "version=$EXPECTED_VERSION"
  echo "build=$EXPECTED_BUILD"
  echo "channel=pre-release"
  echo "arch=arm64"
  echo "signing=ad-hoc"
  echo "hardened_runtime=disabled"
  echo "notarized=no"
  echo "disk_image=$DMG_NAME"
  echo "sha256=$DMG_SHA"
  /usr/bin/du -sh "$DMG_PATH" | /usr/bin/awk '{print "dmg_size="$1}'
} > "$DIST_DIR/DMG-INFO.txt"

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 -c SHA256SUMS
)

echo "==> Pre-release DMG ready"
echo "    dmg: $DMG_PATH"
echo "    sha: $DMG_SHA"
cat "$DIST_DIR/DMG-INFO.txt"
