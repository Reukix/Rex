#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

VERSION="${1:-0.8.1}"
BUILD_NUMBER="${2:-810}"
CONFIGURATION="${3:-Debug}"
DERIVED_DATA="$PROJECT_ROOT/.build/xcode-package"
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP_PATH="$PRODUCTS_DIR/Rex.app"
DIST_DIR="$PROJECT_ROOT/Dist"
ARCHIVE_NAME="Rex-v${VERSION}-macos-arm64-chromium.zip"
STAGING_DIR="$DIST_DIR/staging-$$"

echo "==> Rex Chromium package builder"
echo "    version: $VERSION"
echo "    build:   $BUILD_NUMBER"
echo "    config:  $CONFIGURATION"

"$PROJECT_ROOT/Scripts/verify-apple-silicon.sh"
"$PROJECT_ROOT/Scripts/build-cef-runtime.sh"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required to generate the current Rex.xcodeproj." >&2
  exit 7
fi
xcodegen generate --spec "$PROJECT_ROOT/project.yml"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

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

mkdir -p "$DIST_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/Rex.app"

# Keep a local unzipped copy for quick launch.
rm -rf "$DIST_DIR/Rex.app"
/usr/bin/ditto "$APP_PATH" "$DIST_DIR/Rex.app"

echo "==> Creating zip archive"
(
  cd "$STAGING_DIR"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Rex.app "$DIST_DIR/$ARCHIVE_NAME"
)
rm -rf "$STAGING_DIR"

SHA="$(/usr/bin/shasum -a 256 "$DIST_DIR/$ARCHIVE_NAME" | /usr/bin/awk '{print $1}')"
{
  echo "$SHA  $ARCHIVE_NAME"
} > "$DIST_DIR/SHA256SUMS"

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
  du -sh "$DIST_DIR/Rex.app" | awk '{print "app_size="$1}'
  du -sh "$DIST_DIR/$ARCHIVE_NAME" | awk '{print "zip_size="$1}'
  echo "frameworks:"
  /bin/ls -1 "$DIST_DIR/Rex.app/Contents/Frameworks"
} > "$DIST_DIR/PACKAGE-INFO.txt"

echo "==> Package ready"
echo "    app:  $DIST_DIR/Rex.app"
echo "    zip:  $DIST_DIR/$ARCHIVE_NAME"
echo "    sha:  $SHA"
cat "$DIST_DIR/PACKAGE-INFO.txt"
