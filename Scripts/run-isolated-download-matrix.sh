#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_ROOT/Dist/Rex.app}"
MATRIX_SAMPLE="${2:-${REX_DOWNLOAD_MATRIX_SAMPLE:-all}}"
MATRIX_SECONDS="${REX_DOWNLOAD_MATRIX_SECONDS:-60}"
FIXTURE_ROOT="$PROJECT_ROOT/Tests/Fixtures/download-matrix"
MATRIX_TEMP="$(/usr/bin/mktemp -d /tmp/rex-download-matrix.XXXXXX)"
PORT_FILE="$MATRIX_TEMP/port"
SERVER_LOG="$MATRIX_TEMP/server.log"
SMOKE_LOG="$MATRIX_TEMP/smoke-driver.log"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    /bin/kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  echo "Download matrix driver evidence: $MATRIX_TEMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! "$MATRIX_SECONDS" =~ ^[0-9]+$ ]] ||
    (( MATRIX_SECONDS < 10 || MATRIX_SECONDS > 60 )); then
  echo "REX_DOWNLOAD_MATRIX_SECONDS must be an integer from 10 through 60." >&2
  exit 2
fi
case "$MATRIX_SAMPLE" in
  all|safe.pdf|installer.pkg|setup.sh|invoice.pdf.command|photo.png) ;;
  *)
    echo "Download matrix sample must be all, safe.pdf, installer.pkg, setup.sh, invoice.pdf.command, or photo.png." >&2
    exit 2
    ;;
esac
if [[ ! -x "$APP_PATH/Contents/MacOS/Rex" ]]; then
  echo "Rex executable is missing: $APP_PATH/Contents/MacOS/Rex" >&2
  exit 2
fi

/usr/bin/python3 "$PROJECT_ROOT/Scripts/serve-download-matrix.py" \
  "$FIXTURE_ROOT" "$PORT_FILE" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in {1..50}; do
  [[ -s "$PORT_FILE" ]] && break
  /bin/sleep 0.1
done
if [[ ! -s "$PORT_FILE" ]]; then
  echo "Download matrix fixture server did not start." >&2
  exit 4
fi
PORT="$(<"$PORT_FILE")"
if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
  echo "Download matrix fixture server returned an invalid port." >&2
  exit 4
fi
if [[ "$MATRIX_SAMPLE" == "all" ]]; then
  MATRIX_URL="http://127.0.0.1:$PORT/"
  REQUIRED_SAMPLES=(safe.pdf installer.pkg setup.sh invoice.pdf.command photo.png)
else
  MATRIX_URL="http://127.0.0.1:$PORT/$MATRIX_SAMPLE"
  REQUIRED_SAMPLES=("$MATRIX_SAMPLE")
fi

echo "Rex will open the isolated Chromium download matrix at $MATRIX_URL"
if [[ "$MATRIX_SAMPLE" == "all" ]]; then
  echo "Exercise all five Chromium download cases before the window closes."
else
  echo "Exercise the $MATRIX_SAMPLE case before the window closes."
fi
set +e
REX_SMOKE_INITIAL_URL="$MATRIX_URL" \
REX_PRESERVE_QA_PROFILE=1 \
  "$PROJECT_ROOT/Scripts/run-isolated-rex-smoke.sh" \
  "$APP_PATH" "$MATRIX_SECONDS" 2>&1 | /usr/bin/tee "$SMOKE_LOG"
SMOKE_STATUS=${PIPESTATUS[0]}
set -e
MISSING_REQUESTS=()
for sample in "${REQUIRED_SAMPLES[@]}"; do
  if ! /usr/bin/grep -Fq "\"GET /$sample HTTP/1.1\" 200 -" "$SERVER_LOG"; then
    MISSING_REQUESTS+=("$sample")
  fi
done
if (( ${#MISSING_REQUESTS[@]} > 0 )); then
  echo "Download matrix did not request every fixture: ${MISSING_REQUESTS[*]}" >&2
fi
if [[ "$SMOKE_STATUS" -ne 0 ]]; then
  exit "$SMOKE_STATUS"
fi
if (( ${#MISSING_REQUESTS[@]} > 0 )); then
  exit 5
fi

echo "Isolation and Chromium shutdown passed. GUI state-mapping outcomes require the matrix checklist evidence."
