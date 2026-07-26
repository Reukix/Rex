#!/bin/bash
set -euo pipefail

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Rex build host must be Apple Silicon (arm64)." >&2
  exit 2
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if rg -n "x86_64|macosx64|Intel" \
  "$PROJECT_ROOT/Package.swift" \
  "$PROJECT_ROOT/Chromium" \
  "$PROJECT_ROOT/Sources" \
  "$PROJECT_ROOT/Scripts" \
  --glob '!verify-apple-silicon.sh' \
  --glob '!**/Resources/**'; then
  echo "Intel build configuration detected. Rex v0.2+ is arm64-only." >&2
  exit 3
fi

echo "Apple Silicon-only configuration verified."
