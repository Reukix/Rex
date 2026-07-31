#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

VERSION="${1:-0.9.8}"
BUILD_NUMBER="${2:-983}"
CONFIGURATION="${3:-Release}"
SIGNING_MODE="${REX_PACKAGE_SIGNING_MODE:-adhoc}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
  echo "Version must be a SemVer value without a leading v." >&2
  exit 8
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Build number must contain decimal digits only." >&2
  exit 8
fi
if [[ "$CONFIGURATION" != "Debug" && "$CONFIGURATION" != "Release" ]]; then
  echo "Configuration must be Debug or Release." >&2
  exit 8
fi
if [[ "$SIGNING_MODE" != "adhoc" &&
      "$SIGNING_MODE" != "apple-development" &&
      "$SIGNING_MODE" != "developer-id" ]]; then
  echo "REX_PACKAGE_SIGNING_MODE must be adhoc, apple-development, or developer-id." >&2
  exit 8
fi
SIGNING_IDENTITY="-"
SIGNING_TEAM=""
HARDENED_RUNTIME="NO"
SIGNING_LABEL="ad-hoc"
if [[ "$SIGNING_MODE" == "apple-development" ]]; then
  SIGNING_IDENTITY="${REX_APPLE_DEVELOPMENT_IDENTITY:-}"
  SIGNING_TEAM="${REX_APPLE_DEVELOPMENT_TEAM_ID:-}"
  if [[ "$SIGNING_IDENTITY" != Apple\ Development:* || -z "$SIGNING_TEAM" ]]; then
    echo "Apple Development packaging requires REX_APPLE_DEVELOPMENT_IDENTITY and REX_APPLE_DEVELOPMENT_TEAM_ID." >&2
    exit 8
  fi
  SIGNING_LABEL="apple-development"
elif [[ "$SIGNING_MODE" == "developer-id" ]]; then
  SIGNING_IDENTITY="${REX_DEVELOPER_IDENTITY:-}"
  SIGNING_TEAM="${REX_DEVELOPER_ID_TEAM_ID:-}"
  if [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* || -z "$SIGNING_TEAM" ]]; then
    echo "Developer ID packaging requires REX_DEVELOPER_IDENTITY and REX_DEVELOPER_ID_TEAM_ID." >&2
    exit 8
  fi
  if [[ "$CONFIGURATION" != "Release" ]]; then
    echo "Developer ID packaging requires the Release configuration." >&2
    exit 8
  fi
  HARDENED_RUNTIME="YES"
  SIGNING_LABEL="developer-id"
fi
if [[ "$SIGNING_MODE" != "adhoc" ]] &&
    ! /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/grep -Fq "\"$SIGNING_IDENTITY\""; then
  echo "Requested signing identity is not valid in the current keychain: $SIGNING_IDENTITY" >&2
  exit 8
fi
EXPECTED_MARKETING_VERSION="${VERSION%%-*}"

DERIVED_DATA="$PROJECT_ROOT/.build/xcode-package"
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP_PATH="$PRODUCTS_DIR/Rex.app"
DIST_DIR="$PROJECT_ROOT/Dist"
ARCHIVE_NAME="Rex-v${VERSION}-macos-arm64-chromium.zip"
PUBLISH_DIR="$PROJECT_ROOT/.Dist.next-$$"
BACKUP_DIST="$PROJECT_ROOT/.Dist.previous-$$"
VALIDATION_DIR="$PROJECT_ROOT/.build/package-release-validation"
PUBLISH_COMMITTED=false

cleanup() {
  if [[ -e "$BACKUP_DIST" ]]; then
    if [[ "$PUBLISH_COMMITTED" == true ]]; then
      /bin/rm -rf "$BACKUP_DIST"
    else
      /bin/rm -rf "$DIST_DIR"
      /bin/mv "$BACKUP_DIST" "$DIST_DIR"
    fi
  fi
  /bin/rm -rf "$PUBLISH_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> Rex Chromium package builder"
echo "    version: $VERSION"
echo "    build:   $BUILD_NUMBER"
echo "    config:  $CONFIGURATION"
echo "    signing: $SIGNING_LABEL"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$DERIVED_DATA/ModuleCache.noindex}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "==> Validating release metadata"
swift run --disable-sandbox RexReleaseValidator \
  "$PROJECT_ROOT" \
  "$VALIDATION_DIR" \
  "$VERSION" \
  "$BUILD_NUMBER"

"$PROJECT_ROOT/Scripts/verify-apple-silicon.sh"
"$PROJECT_ROOT/Scripts/build-cef-runtime.sh"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required to generate the current Rex.xcodeproj." >&2
  exit 7
fi
xcodegen generate --spec "$PROJECT_ROOT/project.yml"

echo "==> Building Rex.app with embedded CEF/Chromium"
xcodebuild \
  -project "$PROJECT_ROOT/Rex.xcodeproj" \
  -scheme Rex \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  build \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$SIGNING_TEAM" \
  ENABLE_HARDENED_RUNTIME="$HARDENED_RUNTIME" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MARKETING_VERSION="$EXPECTED_MARKETING_VERSION"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build product missing: $APP_PATH" >&2
  exit 5
fi

verify_bundle_version() {
  local bundle_path="$1"
  local bundle_name="$2"
  local info_plist="$bundle_path/Contents/Info.plist"
  local actual_version
  local actual_build

  if [[ ! -f "$info_plist" ]]; then
    echo "$bundle_name Info.plist is missing: $info_plist" >&2
    exit 9
  fi

  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
  actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
  if [[ "$actual_version" != "$EXPECTED_MARKETING_VERSION" || "$actual_build" != "$BUILD_NUMBER" ]]; then
    echo "$bundle_name version mismatch: expected $EXPECTED_MARKETING_VERSION/$BUILD_NUMBER, received $actual_version/$actual_build." >&2
    exit 9
  fi
}

verify_bundle_version "$APP_PATH" "Rex.app"

BLUETOOTH_USAGE_DESCRIPTION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :NSBluetoothAlwaysUsageDescription' \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
)"
if [[ -z "$BLUETOOTH_USAGE_DESCRIPTION" ]]; then
  echo "Rex.app must declare NSBluetoothAlwaysUsageDescription for Chromium Web Bluetooth and security-key requests." >&2
  exit 9
fi

echo "==> Verifying Chromium runtime embedding"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
test -d "$FRAMEWORKS/Chromium Embedded Framework.framework"
test -d "$FRAMEWORKS/Rex Helper.app"
test -d "$FRAMEWORKS/Rex Helper (GPU).app"
test -d "$FRAMEWORKS/Rex Helper (Renderer).app"
test -d "$FRAMEWORKS/Rex Helper (Plugin).app"
test -d "$FRAMEWORKS/Rex Helper (Alerts).app"
test -f "$APP_PATH/Contents/Resources/CEF-LICENSE.txt"

for helper_name in \
  "Rex Helper" \
  "Rex Helper (GPU)" \
  "Rex Helper (Renderer)" \
  "Rex Helper (Plugin)" \
  "Rex Helper (Alerts)"; do
  verify_bundle_version "$FRAMEWORKS/$helper_name.app" "$helper_name.app"
done

verify_arm64_binary() {
  local binary_path="$1"
  local binary_name="$2"
  local architectures

  architectures="$(/usr/bin/lipo -archs "$binary_path")"
  echo "    $binary_name: $architectures"
  if [[ "$architectures" != "arm64" ]]; then
    echo "$binary_name must be an arm64-only binary; received: $architectures" >&2
    exit 6
  fi
}

verify_arm64_binary "$APP_PATH/Contents/MacOS/Rex" "Rex"
verify_arm64_binary \
  "$FRAMEWORKS/Chromium Embedded Framework.framework/Chromium Embedded Framework" \
  "Chromium Embedded Framework"
for helper_name in \
  "Rex Helper" \
  "Rex Helper (GPU)" \
  "Rex Helper (Renderer)" \
  "Rex Helper (Plugin)" \
  "Rex Helper (Alerts)"; do
  verify_arm64_binary \
    "$FRAMEWORKS/$helper_name.app/Contents/MacOS/$helper_name" \
    "$helper_name"
done

echo "==> Verifying removed Rex password integration"
if /usr/bin/otool -L "$APP_PATH/Contents/MacOS/Rex" \
    | /usr/bin/grep -q '/AuthenticationServices\.framework/'; then
  echo "Rex must not link AuthenticationServices after password integration removal." >&2
  exit 11
fi
if [[ -d "$APP_PATH/Contents/Library/SystemExtensions" ]] &&
    /usr/bin/find "$APP_PATH/Contents/Library/SystemExtensions" \
      -name '*.systemextension' -print -quit \
      | /usr/bin/grep -q .; then
  echo "Rex.app unexpectedly contains a system extension." >&2
  exit 11
fi

echo "==> Verifying $SIGNING_LABEL code signatures"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_PATH"
verify_signing_identity() {
  local code_path="$1"
  local label="$2"
  local details
  local authority
  local team_id

  details="$(/usr/bin/codesign -d --verbose=4 "$code_path" 2>&1)"
  authority="$(printf '%s\n' "$details" | /usr/bin/awk -F= '/^Authority=/{print $2; exit}')"
  team_id="$(printf '%s\n' "$details" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
  if [[ "$authority" != "$SIGNING_IDENTITY" ]]; then
    echo "$label signing authority mismatch: expected $SIGNING_IDENTITY, received $authority." >&2
    exit 12
  fi
  if [[ "$team_id" != "$SIGNING_TEAM" ]]; then
    echo "$label TeamIdentifier mismatch: expected $SIGNING_TEAM, received $team_id." >&2
    exit 12
  fi
  if [[ "$SIGNING_MODE" == "developer-id" ]] &&
      ! printf '%s\n' "$details" | /usr/bin/grep -Eq '(^| )flags=.*runtime'; then
    echo "$label Developer ID signature is missing Hardened Runtime." >&2
    exit 12
  fi
}

if [[ "$SIGNING_MODE" != "adhoc" ]]; then
  verify_signing_identity "$APP_PATH" "Rex.app"
  while IFS= read -r -d '' code_path; do
    if /usr/bin/file -b "$code_path" | /usr/bin/grep -q 'Mach-O'; then
      verify_signing_identity "$code_path" "Nested Mach-O"
    fi
  done < <(/usr/bin/find "$APP_PATH/Contents" -type f -print0)
fi

/bin/rm -rf "$PUBLISH_DIR" "$BACKUP_DIST"
mkdir -p "$PUBLISH_DIR"

# Assemble the entire handoff directory away from Dist so a failed copy,
# archive, checksum, or inventory write cannot mix two releases.
/usr/bin/ditto "$APP_PATH" "$PUBLISH_DIR/Rex.app"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$PUBLISH_DIR/Rex.app"
if /usr/bin/find "$PUBLISH_DIR/Rex.app" -name console.log -print -quit | /usr/bin/grep -q .; then
  echo "Unexpected console.log found in Rex.app." >&2
  exit 10
fi

echo "==> Creating zip archive"
(
  cd "$PUBLISH_DIR"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Rex.app "$ARCHIVE_NAME"
)
/usr/bin/unzip -tq "$PUBLISH_DIR/$ARCHIVE_NAME"
if /usr/bin/unzip -Z1 "$PUBLISH_DIR/$ARCHIVE_NAME" \
    | /usr/bin/grep -E '(^|/)console\.log$' >/dev/null; then
  echo "Unexpected console.log found in release archive." >&2
  exit 10
fi

SHA="$(/usr/bin/shasum -a 256 "$PUBLISH_DIR/$ARCHIVE_NAME" | /usr/bin/awk '{print $1}')"

{
  echo "$SHA  $ARCHIVE_NAME"
} > "$PUBLISH_DIR/SHA256SUMS"

# Bundle inventory for release verification.
{
  echo "product=Rex.app"
  echo "version=$VERSION"
  echo "build=$BUILD_NUMBER"
  echo "configuration=$CONFIGURATION"
  echo "chromium=150.0.7871.129"
  echo "cef=150.0.14+g7c1aa68+chromium-150.0.7871.129"
  echo "cef_distribution=standard"
  echo "content_blocking=rex-curated-domain-catalog+chromium-extension-dnr"
  echo "extension_runtime=chromium-native-extension-api+browser-target-cdp-pipe"
  echo "extension_install=developerPrivate.loadUnpacked-persistent-unpacked"
  echo "extension_update=developerPrivate.reload"
  echo "extension_enable_disable=management.setEnabled"
  echo "extension_query_remove=browser-target-cdp-over-remote-debugging-pipe"
  echo "extension_lifecycle=hot-install-enable-disable-update-remove"
  echo "extension_startup_navigation=extension-ready-generation-barrier"
  echo "extension_page_reload=automatic-after-hot-runtime-change"
  echo "cef_shutdown=nsapplication-run-hook-after-event-loop-return"
  echo "extension_pipe_shutdown=before-cef-shutdown"
  echo "extension_pipe_fd_release=after-cef-shutdown"
  echo "rex_password_integration=absent"
  echo "performance_layer=rex-thorium-hybrid-v1.3"
  echo "devtools=cef-chromium-devtools"
  echo "signing=$SIGNING_LABEL"
  echo "hardened_runtime=$HARDENED_RUNTIME"
  echo "arch=arm64"
  echo "archive=$ARCHIVE_NAME"
  echo "sha256=$SHA"
  echo "app_path=$DIST_DIR/Rex.app"
  du -sh "$PUBLISH_DIR/Rex.app" | awk '{print "app_size="$1}'
  du -sh "$PUBLISH_DIR/$ARCHIVE_NAME" | awk '{print "zip_size="$1}'
  echo "frameworks:"
  /bin/ls -1 "$PUBLISH_DIR/Rex.app/Contents/Frameworks"
} > "$PUBLISH_DIR/PACKAGE-INFO.txt"

(
  cd "$PUBLISH_DIR"
  /usr/bin/shasum -a 256 -c SHA256SUMS
)

# Publish the verified directory as one release set. If the second rename
# fails or a handled signal arrives between renames, cleanup restores Dist.
if [[ -e "$DIST_DIR" ]]; then
  /bin/mv "$DIST_DIR" "$BACKUP_DIST"
fi
/bin/mv "$PUBLISH_DIR" "$DIST_DIR"
PUBLISH_COMMITTED=true
/bin/rm -rf "$BACKUP_DIST"

echo "==> Package ready"
echo "    app:  $DIST_DIR/Rex.app"
echo "    zip:  $DIST_DIR/$ARCHIVE_NAME"
echo "    sha:  $SHA"
cat "$DIST_DIR/PACKAGE-INFO.txt"
