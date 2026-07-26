#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMAKE_BIN="$(command -v cmake || true)"
PARALLEL_JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || true)"

if [[ -z "$CMAKE_BIN" ]]; then
  echo "CMake is required to build the CEF bridge." >&2
  exit 4
fi

if [[ ! "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  PARALLEL_JOBS=4
fi

"$PROJECT_ROOT/Scripts/verify-apple-silicon.sh"
"$PROJECT_ROOT/Scripts/fetch-cef.sh"

# External rule engines are not built; the curated catalog lives in RexPrivacyEngine.

"$CMAKE_BIN" \
  -S "$PROJECT_ROOT/Chromium" \
  -B "$PROJECT_ROOT/.build/rex-chromium" \
  -G Ninja \
  -DPROJECT_ARCH=arm64 \
  -DCMAKE_BUILD_TYPE=Release

"$CMAKE_BIN" \
  --build "$PROJECT_ROOT/.build/rex-chromium" \
  --target RexChromiumBridge RexCEFHelper \
  --parallel "$PARALLEL_JOBS"
