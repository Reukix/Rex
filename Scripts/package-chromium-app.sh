#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

VERSION="${1:-0.9.0}"
BUILD_NUMBER="${2:-900}"
CONFIGURATION="${3:-Debug}"

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

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "==> Validating release metadata"
swift run RexReleaseValidator \
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
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MARKETING_VERSION="${VERSION%%-*}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build product missing: $APP_PATH" >&2
  exit 5
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

ARCH_CHECK="$(/usr/bin/lipo -info "$APP_PATH/Contents/MacOS/Rex" | /usr/bin/tr -d '\n')"
echo "    binary: $ARCH_CHECK"
if [[ "$ARCH_CHECK" != *"arm64"* ]]; then
  echo "Expected arm64 binary." >&2
  exit 6
fi

/bin/rm -rf "$PUBLISH_DIR" "$BACKUP_DIST"
mkdir -p "$PUBLISH_DIR"

# Assemble the entire handoff directory away from Dist so a failed copy,
# archive, checksum, or inventory write cannot mix two releases.
/usr/bin/ditto "$APP_PATH" "$PUBLISH_DIR/Rex.app"

echo "==> Creating zip archive"
(
  cd "$PUBLISH_DIR"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Rex.app "$ARCHIVE_NAME"
)
/usr/bin/unzip -tq "$PUBLISH_DIR/$ARCHIVE_NAME"

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
  echo "content_blocking=rex-curated-domain-catalog"
  echo "performance_layer=rex-thorium-hybrid-v1.3"
  echo "devtools=cef-chromium-devtools"
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
