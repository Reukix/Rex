#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-}"
UPDATE_MANIFEST="${2:-}"
UPDATE_SIGNATURE="${3:-}"
UPDATE_PACKAGE="${4:-}"
ROLLBACK_PACKAGE="${5:-}"
CURRENT_BUILD="${6:-}"
EXPECTED_TEAM_ID="${REX_DEVELOPER_ID_TEAM_ID:-}"
UPDATE_PUBLIC_KEY="${REX_APP_UPDATE_PUBLIC_KEY:-}"

if [[ -z "$APP_PATH" || -z "$UPDATE_MANIFEST" || -z "$UPDATE_SIGNATURE" ||
      -z "$UPDATE_PACKAGE" || -z "$ROLLBACK_PACKAGE" || -z "$CURRENT_BUILD" ]]; then
  echo "usage: $0 <Rex.app> <update-manifest.json> <update-manifest.sig> <update.zip> <rollback.zip> <current-build>" >&2
  exit 2
fi
if [[ ! "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Current build must contain decimal digits only." >&2
  exit 2
fi
if [[ -z "$EXPECTED_TEAM_ID" || -z "$UPDATE_PUBLIC_KEY" ]]; then
  echo "REX_DEVELOPER_ID_TEAM_ID and REX_APP_UPDATE_PUBLIC_KEY are required for formal distribution." >&2
  exit 3
fi
for required_path in \
  "$APP_PATH" \
  "$UPDATE_MANIFEST" \
  "$UPDATE_SIGNATURE" \
  "$UPDATE_PACKAGE" \
  "$ROLLBACK_PACKAGE"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Required distribution input is missing: $required_path" >&2
    exit 4
  fi
done

verify_developer_id_bundle() {
  local bundle_path="$1"
  local label="$2"

  /usr/bin/codesign --verify --deep --strict --verbose=4 "$bundle_path"
  verify_code_identity "$bundle_path" "$label"

  while IFS= read -r -d '' code_path; do
    if /usr/bin/file -b "$code_path" | /usr/bin/grep -q 'Mach-O'; then
      verify_code_identity "$code_path" "$label nested code"
    fi
  done < <(/usr/bin/find "$bundle_path/Contents" -type f -print0)

  /usr/bin/xcrun stapler validate "$bundle_path"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$bundle_path"
}

verify_code_identity() {
  local code_path="$1"
  local label="$2"
  local details
  local authority
  local team_id

  details="$(/usr/bin/codesign -d --verbose=4 "$code_path" 2>&1)"
  authority="$(printf '%s\n' "$details" | /usr/bin/awk -F= '/^Authority=/{print $2; exit}')"
  team_id="$(printf '%s\n' "$details" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
  if [[ "$authority" != Developer\ ID\ Application:* ]]; then
    echo "$label is not signed with Developer ID Application: $authority" >&2
    exit 5
  fi
  if [[ "$team_id" != "$EXPECTED_TEAM_ID" ]]; then
    echo "$label Team ID mismatch: expected $EXPECTED_TEAM_ID, received $team_id" >&2
    exit 5
  fi
  if ! printf '%s\n' "$details" | /usr/bin/grep -Eq '(^| )flags=.*runtime'; then
    echo "$label does not enable Hardened Runtime." >&2
    exit 5
  fi
}

verify_archive_paths() {
  local archive_path="$1"
  /usr/bin/python3 "$PROJECT_ROOT/Scripts/verify-update-archive.py" "$archive_path"
}

verify_archive_bundle() {
  local archive_path="$1"
  local label="$2"
  local destination="$3"
  local expected_build="$4"
  local archive_build
  verify_archive_paths "$archive_path"
  /usr/bin/ditto -x -k "$archive_path" "$destination"
  if [[ ! -d "$destination/Rex.app" ]]; then
    echo "$label archive did not extract one Rex.app." >&2
    exit 6
  fi
  archive_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$destination/Rex.app/Contents/Info.plist")"
  if [[ "$archive_build" != "$expected_build" ]]; then
    echo "$label archive build mismatch: expected $expected_build, received $archive_build" >&2
    exit 6
  fi
  verify_developer_id_bundle "$destination/Rex.app" "$label Rex.app"
}

echo "==> Verifying staged Developer ID application"
verify_developer_id_bundle "$APP_PATH" "staged Rex.app"
STAGED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
if [[ ! "$STAGED_BUILD" =~ ^[0-9]+$ || "$STAGED_BUILD" -le "$CURRENT_BUILD" ]]; then
  echo "Staged Rex.app build must be newer than current build $CURRENT_BUILD; received $STAGED_BUILD." >&2
  exit 5
fi

echo "==> Verifying independent application-update signature and rollback artifact"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  swift run --package-path "$PROJECT_ROOT" --disable-sandbox RexDistributionGate \
  "$UPDATE_MANIFEST" \
  "$UPDATE_SIGNATURE" \
  "$UPDATE_PACKAGE" \
  "$ROLLBACK_PACKAGE" \
  "$CURRENT_BUILD" \
  "$STAGED_BUILD" \
  "$UPDATE_PUBLIC_KEY"

GATE_TEMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/rex-distribution-gate.XXXXXX")"
cleanup() {
  case "$GATE_TEMP" in
    /tmp/rex-distribution-gate.*|/private/tmp/rex-distribution-gate.*|"${TMPDIR:-/tmp}"/rex-distribution-gate.*)
      /usr/bin/find "$GATE_TEMP" -depth -delete
      ;;
    *)
      echo "Refusing to remove unexpected gate path: $GATE_TEMP" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/bin/mkdir "$GATE_TEMP/update" "$GATE_TEMP/rollback"
verify_archive_bundle "$UPDATE_PACKAGE" "update" "$GATE_TEMP/update" "$STAGED_BUILD"
verify_archive_bundle "$ROLLBACK_PACKAGE" "rollback" "$GATE_TEMP/rollback" "$CURRENT_BUILD"

echo "Formal distribution gates passed: Developer ID, Hardened Runtime, notarization staple, Gatekeeper, signed update, and rollback artifact."
