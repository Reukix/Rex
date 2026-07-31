#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF_SOURCE="$PROJECT_ROOT/Vendor/CEF/current/Release/Chromium Embedded Framework.framework"
HELPER_SOURCE="$PROJECT_ROOT/.build/rex-chromium/RexCEFHelper.app/Contents/MacOS/RexCEFHelper"
FRAMEWORKS_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
RESOURCES_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
CEF_DESTINATION="$FRAMEWORKS_DIR/Chromium Embedded Framework.framework"

if [[ "$CURRENT_ARCH" != "arm64" && "$NATIVE_ARCH_ACTUAL" != "arm64" ]]; then
  echo "Rex only supports Apple Silicon (arm64)." >&2
  exit 2
fi

if [[ ! -x "$HELPER_SOURCE" || ! -d "$CEF_SOURCE" ]]; then
  echo "CEF runtime is missing. Run Scripts/build-cef-runtime.sh first." >&2
  exit 3
fi

mkdir -p "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
rm -rf "$CEF_DESTINATION"
mkdir -p "$CEF_DESTINATION/Versions/A"
/usr/bin/ditto "$CEF_SOURCE" "$CEF_DESTINATION/Versions/A"
ln -sfn A "$CEF_DESTINATION/Versions/Current"
ln -sfn Versions/Current/Chromium\ Embedded\ Framework "$CEF_DESTINATION/Chromium Embedded Framework"
ln -sfn Versions/Current/Libraries "$CEF_DESTINATION/Libraries"
ln -sfn Versions/Current/Resources "$CEF_DESTINATION/Resources"

HELPER_NAMES=(
  "Rex Helper"
  "Rex Helper (Alerts)"
  "Rex Helper (GPU)"
  "Rex Helper (Plugin)"
  "Rex Helper (Renderer)"
)
HELPER_IDS=(
  "com.rex.browser.helper"
  "com.rex.browser.helper.alerts"
  "com.rex.browser.helper.gpu"
  "com.rex.browser.helper.plugin"
  "com.rex.browser.helper.renderer"
)

for index in "${!HELPER_NAMES[@]}"; do
  name="${HELPER_NAMES[$index]}"
  bundle_id="${HELPER_IDS[$index]}"
  bundle="$FRAMEWORKS_DIR/$name.app"
  executable="$bundle/Contents/MacOS/$name"
  rm -rf "$bundle"
  mkdir -p "$bundle/Contents/MacOS"
  /bin/cp "$HELPER_SOURCE" "$executable"
  /bin/chmod 755 "$executable"
  /bin/cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key><string>$CURRENT_PROJECT_VERSION</string>
  <key>LSFileQuarantineEnabled</key><true/>
  <key>LSMinimumSystemVersion</key><string>$MACOSX_DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
done

/usr/bin/ditto "$PROJECT_ROOT/Vendor/CEF/current/LICENSE.txt" "$RESOURCES_DIR/CEF-LICENSE.txt"
/usr/bin/ditto "$PROJECT_ROOT/Vendor/CEF/current/CREDITS.html" "$RESOURCES_DIR/Chromium-CREDITS.html"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  codesign_options=(--force --sign "$identity")
  if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" && "$identity" != "-" ]]; then
    codesign_options+=(--options runtime --timestamp)
  else
    codesign_options+=(--timestamp=none)
  fi
  while IFS= read -r library; do
    /usr/bin/codesign "${codesign_options[@]}" "$library"
  done < <(/usr/bin/find "$CEF_DESTINATION/Versions/A/Libraries" -type f -name '*.dylib')
  /usr/bin/codesign "${codesign_options[@]}" "$CEF_DESTINATION"
  for name in "${HELPER_NAMES[@]}"; do
    /usr/bin/codesign "${codesign_options[@]}" "$FRAMEWORKS_DIR/$name.app"
  done
fi

echo "Embedded CEF $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CEF_DESTINATION/Resources/Info.plist") for arm64."
