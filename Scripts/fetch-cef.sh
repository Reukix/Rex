#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$PROJECT_ROOT/Chromium/cef.lock.json"
VENDOR_ROOT="$PROJECT_ROOT/Vendor/CEF"
ARCHIVE_ROOT="$PROJECT_ROOT/Artifacts/CEF"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Rex only supports Apple Silicon (arm64)." >&2
  exit 2
fi

read_lock() {
  /usr/bin/python3 - "$LOCK_FILE" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)[sys.argv[2]]
print(value)
PY
}

CEF_VERSION="$(read_lock cefVersion)"
CEF_URL="$(read_lock source)"
CEF_FILENAME="$(read_lock filename)"
CEF_SHA1="$(read_lock officialSha1)"
CEF_SHA256="$(read_lock sha256)"
CEF_DIRNAME="${CEF_FILENAME%.tar.bz2}"
CEF_ARCHIVE="$ARCHIVE_ROOT/$CEF_FILENAME"
CEF_DESTINATION="$VENDOR_ROOT/$CEF_DIRNAME"

mkdir -p "$ARCHIVE_ROOT" "$VENDOR_ROOT"

if [[ ! -f "$CEF_ARCHIVE" ]]; then
  echo "Downloading CEF $CEF_VERSION for Apple Silicon..."
  /usr/bin/curl --fail --location --continue-at - --progress-bar "$CEF_URL" --output "$CEF_ARCHIVE"
fi

ACTUAL_SHA1="$(/usr/bin/shasum "$CEF_ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL_SHA1" != "$CEF_SHA1" ]]; then
  echo "CEF SHA-1 mismatch. Expected $CEF_SHA1, received $ACTUAL_SHA1." >&2
  exit 3
fi

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$CEF_ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$CEF_SHA256" != "PENDING_AFTER_FIRST_VERIFIED_DOWNLOAD" && "$ACTUAL_SHA256" != "$CEF_SHA256" ]]; then
  echo "CEF SHA-256 mismatch. Expected $CEF_SHA256, received $ACTUAL_SHA256." >&2
  exit 4
fi

if [[ ! -d "$CEF_DESTINATION" ]]; then
  echo "Extracting CEF..."
  /usr/bin/tar -xjf "$CEF_ARCHIVE" -C "$VENDOR_ROOT"
fi

if [[ ! -d "$CEF_DESTINATION/Release/Chromium Embedded Framework.framework" ]]; then
  echo "CEF framework is missing after extraction." >&2
  exit 5
fi

FRAMEWORK_ARCHS="$(/usr/bin/lipo -archs "$CEF_DESTINATION/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework")"
if [[ "$FRAMEWORK_ARCHS" != "arm64" ]]; then
  echo "CEF framework must contain only arm64, found: $FRAMEWORK_ARCHS" >&2
  exit 6
fi

ln -sfn "$CEF_DIRNAME" "$VENDOR_ROOT/current"

echo "CEF ready: $CEF_DESTINATION"
echo "SHA-256: $ACTUAL_SHA256"
