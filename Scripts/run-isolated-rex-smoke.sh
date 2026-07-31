#!/bin/bash
set -euo pipefail

rex_project_root="$(cd "$(dirname "$0")/.." && pwd)"
rex_app_path="${1:-$rex_project_root/Dist/Rex.app}"
rex_hold_seconds="${2:-${REX_SMOKE_SECONDS:-2}}"
rex_preserve_profile="${REX_PRESERVE_QA_PROFILE:-0}"
rex_initial_url="${REX_SMOKE_INITIAL_URL:-}"

if [[ "$rex_app_path" != /* ]]; then
  rex_app_path="$PWD/$rex_app_path"
fi
rex_executable="$rex_app_path/Contents/MacOS/Rex"

if [[ ! -x "$rex_executable" ]]; then
  echo "Rex executable is missing or not executable: $rex_executable" >&2
  exit 2
fi
if [[ ! "$rex_hold_seconds" =~ ^[0-9]+$ ]] ||
    (( rex_hold_seconds > 60 )); then
  echo "Smoke duration must be an integer from 0 through 60 seconds." >&2
  exit 2
fi
if [[ "$rex_preserve_profile" != "0" && "$rex_preserve_profile" != "1" ]]; then
  echo "REX_PRESERVE_QA_PROFILE must be 0 or 1." >&2
  exit 2
fi
if [[ -n "$rex_initial_url" &&
      ! "$rex_initial_url" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?/ ]]; then
  echo "REX_SMOKE_INITIAL_URL must be a loopback HTTP URL." >&2
  exit 2
fi

if /usr/bin/pgrep -x Rex >/dev/null 2>&1 ||
    /usr/bin/pgrep -f '/Rex Helper.*\.app/Contents/MacOS/Rex Helper' >/dev/null 2>&1; then
  echo "Refusing smoke test while a Rex or Rex Helper process is running." >&2
  exit 3
fi

rex_real_home="${HOME:?HOME is required to identify user-owned Rex data}"
rex_real_roots=(
  "$rex_real_home/Library/Application Support/Rex"
  "$rex_real_home/Library/Preferences/com.rex.browser.plist"
  "$rex_real_home/Library/Caches/com.rex.browser"
  "$rex_real_home/Library/Saved Application State/com.rex.browser.savedState"
  "$rex_real_home/Library/HTTPStorages/com.rex.browser"
  "$rex_real_home/Library/HTTPStorages/com.rex.browser.binarycookies"
  "$rex_real_home/Library/WebKit/com.rex.browser"
  "$rex_real_home/Library/Cookies/com.rex.browser.binarycookies"
  "$rex_real_home/Library/Containers/com.rex.browser"
  "$rex_real_home/Library/Application Scripts/com.rex.browser"
  "$rex_real_home/Library/Logs/Rex"
)

rex_real_state_snapshot() {
  for rex_root in "${rex_real_roots[@]}"; do
    if [[ -e "$rex_root" || -L "$rex_root" ]]; then
      if [[ -d "$rex_root" && ! -L "$rex_root" ]]; then
        /usr/bin/find -s "$rex_root" -xdev \
          -exec /usr/bin/stat -f '%N|%HT|%m|%c|%z|%Y' {} \;
      else
        /usr/bin/stat -f '%N|%HT|%m|%c|%z|%Y' "$rex_root"
      fi
    else
      echo "MISSING|$rex_root"
    fi
  done
}

rex_snapshot_fingerprint() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

rex_smoke_home=""
rex_main_pid=""
rex_real_fingerprint_before=""
rex_real_metadata_before=""
rex_real_metadata_after=""
rex_real_metadata_diff=""

rex_verify_real_state_unchanged() {
  rex_real_state_snapshot > "$rex_real_metadata_after"
  rex_real_fingerprint_after="$(rex_snapshot_fingerprint "$rex_real_metadata_after")"
  if [[ "$rex_real_fingerprint_after" == "$rex_real_fingerprint_before" ]]; then
    return 0
  fi
  /usr/bin/diff -u \
    "$rex_real_metadata_before" \
    "$rex_real_metadata_after" > "$rex_real_metadata_diff" || true
  echo "User-owned Rex data changed during an isolated smoke test." >&2
  echo "Metadata-only evidence: $rex_real_metadata_diff" >&2
  echo "No automatic rollback was attempted." >&2
  return 1
}

rex_process_is_running() {
  rex_process_state="$(
    /bin/ps -o state= -p "$1" 2>/dev/null |
      /usr/bin/awk 'NR == 1 { print substr($1, 1, 1) }' || true
  )"
  rex_process_command="$(
    /bin/ps -o command= -p "$1" 2>/dev/null |
      /usr/bin/awk 'NR == 1 { print }' || true
  )"
  [[ -n "$rex_process_state" && "$rex_process_state" != "Z" &&
     ( "$rex_process_command" == "$rex_executable" ||
       "$rex_process_command" == "$rex_executable "* ) ]]
}

rex_request_normal_termination() {
  rex_running_main_pids="$(/usr/bin/pgrep -x Rex || true)"
  if [[ "$rex_running_main_pids" != "$1" ]]; then
    echo "Refusing quit because the isolated Rex is not the only Rex process." >&2
    return 3
  fi
  if rex_quit_output="$(/usr/bin/osascript -l JavaScript -e '
    ObjC.import("AppKit")
    function run(argv) {
      const pid = Number(argv[0])
      const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid)
      if (!app) throw new Error("The isolated Rex process is no longer running.")
      if (!app.terminate) throw new Error("Cocoa rejected the termination request.")
    }
  ' "$1" 2>&1)"; then
    return 0
  fi
  echo "$rex_quit_output" >&2
  return 4
}

rex_cleanup() {
  rex_status=$?
  trap - EXIT INT TERM

  if [[ -n "$rex_main_pid" ]]; then
    if rex_process_is_running "$rex_main_pid"; then
      /bin/kill -TERM "$rex_main_pid" 2>/dev/null || true
      for _ in {1..50}; do
        rex_process_is_running "$rex_main_pid" || break
        /bin/sleep 0.1
      done
      if rex_process_is_running "$rex_main_pid"; then
        /bin/kill -KILL "$rex_main_pid" 2>/dev/null || true
      fi
    fi
    wait "$rex_main_pid" 2>/dev/null || true
  fi

  if [[ -n "$rex_real_fingerprint_before" ]]; then
    if ! rex_verify_real_state_unchanged; then
      rex_status=9
    fi
    rex_real_fingerprint_before=""
  fi

  if [[ -n "$rex_smoke_home" && -d "$rex_smoke_home" ]]; then
    if [[ "$rex_status" -eq 0 && "$rex_preserve_profile" == "0" ]]; then
      case "$rex_smoke_home" in
        /tmp/rex-qa-smoke.*)
          /usr/bin/find "$rex_smoke_home" -depth -delete
          ;;
        *)
          echo "Refusing to remove unexpected QA path: $rex_smoke_home" >&2
          rex_status=4
          ;;
      esac
    else
      echo "Isolated QA profile preserved at: $rex_smoke_home" >&2
    fi
  fi
  exit "$rex_status"
}

trap rex_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rex_smoke_home="$(/usr/bin/mktemp -d /tmp/rex-qa-smoke.XXXXXX)"
/bin/mkdir -p \
  "$rex_smoke_home/Downloads/Rex" \
  "$rex_smoke_home/Library/Application Support" \
  "$rex_smoke_home/Library/Caches" \
  "$rex_smoke_home/Library/Preferences"
rex_smoke_log="$rex_smoke_home/rex-smoke.log"
rex_isolated_profile="$rex_smoke_home/Library/Application Support/Rex"
rex_real_metadata_before="$rex_smoke_home/user-owned-metadata-before.txt"
rex_real_metadata_after="$rex_smoke_home/user-owned-metadata-after.txt"
rex_real_metadata_diff="$rex_smoke_home/user-owned-metadata.diff"
rex_real_state_snapshot > "$rex_real_metadata_before"
rex_real_fingerprint_before="$(rex_snapshot_fingerprint "$rex_real_metadata_before")"
# Keep the launch in a later timestamp second so same-size writes cannot hide
# behind the one-second resolution of BSD stat metadata.
/bin/sleep 1

echo "Launching isolated Rex smoke test"
echo "  app:     $rex_app_path"
echo "  profile: $rex_isolated_profile"

# Match CEF's macOS test clients: isolated QA must not query or modify the
# user's login keychain for Chromium profile encryption state.
CFFIXED_USER_HOME="$rex_smoke_home" \
  REX_QA_ISOLATED=1 \
  REX_QA_INITIAL_URL="$rex_initial_url" \
  REX_QA_DOWNLOAD_DIRECTORY="$rex_smoke_home/Downloads/Rex" \
  "$rex_executable" --use-mock-keychain >"$rex_smoke_log" 2>&1 &
rex_main_pid=$!

rex_ready=false
for _ in {1..150}; do
  if ! rex_process_is_running "$rex_main_pid"; then
    break
  fi
  if [[ -f "$rex_isolated_profile/Browser.sqlite" &&
        -d "$rex_isolated_profile/Chromium" ]]; then
    rex_ready=true
    break
  fi
  /bin/sleep 0.1
done

if [[ "$rex_ready" != true ]]; then
  echo "Rex did not create its isolated profile within 15 seconds." >&2
  /usr/bin/tail -n 80 "$rex_smoke_log" >&2 || true
  exit 5
fi

/bin/sleep "$rex_hold_seconds"
if ! rex_request_normal_termination "$rex_main_pid"; then
  echo "Rex rejected the normal Cocoa termination request." >&2
  exit 6
fi
for _ in {1..100}; do
  rex_process_is_running "$rex_main_pid" || break
  /bin/sleep 0.1
done
if rex_process_is_running "$rex_main_pid"; then
  echo "Rex did not exit within 10 seconds after a Cocoa termination request." >&2
  exit 6
fi

rex_exit_status=0
wait "$rex_main_pid" || rex_exit_status=$?
rex_main_pid=""
if [[ "$rex_exit_status" -ne 0 ]]; then
  echo "Rex exited with status $rex_exit_status." >&2
  /usr/bin/tail -n 80 "$rex_smoke_log" >&2 || true
  exit 7
fi
if ! /usr/bin/grep -Fq '[Rex] CEF shutdown completed.' "$rex_smoke_log"; then
  echo "Rex exited without confirming final CEF shutdown." >&2
  /usr/bin/tail -n 80 "$rex_smoke_log" >&2 || true
  exit 7
fi

rex_remaining_helpers=""
for _ in {1..20}; do
  rex_remaining_helpers="$(
    /usr/bin/pgrep -f '/Rex Helper.*\.app/Contents/MacOS/Rex Helper' || true
  )"
  [[ -z "$rex_remaining_helpers" ]] && break
  /bin/sleep 0.1
done
if [[ -n "$rex_remaining_helpers" ]]; then
  echo "Rex Helper processes remained after shutdown: $rex_remaining_helpers" >&2
  exit 8
fi

if ! rex_verify_real_state_unchanged; then
  rex_real_fingerprint_before=""
  exit 9
fi
rex_real_fingerprint_before=""

echo "Isolated smoke test passed; user-owned Rex data was unchanged."
