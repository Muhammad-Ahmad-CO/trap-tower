#!/usr/bin/env bash
# Trap Tower touch-test runner (Lane B).
# Usage:
#   run_touch_test.sh [--project DIR] [--timeout SECS] -- [touch-test args...]
# With no args, runs game mode against the repo project and writes the
# report to ~/workspace/trap-tower/verification/touch-test-report.txt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GODOT_BIN="${GODOT_BIN:-$HOME/workspace/highway-roadster/godot-tools/Godot_v4.3-stable_linux.x86_64}"
PROJECT="$REPO_ROOT/godot"
TIMEOUT_SECS="${TOUCH_TEST_TIMEOUT:-300}"
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --timeout) TIMEOUT_SECS="$2"; shift 2 ;;
    --) shift; ARGS=("$@"); break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ ! -x "$GODOT_BIN" ]]; then
  echo "ERROR: Godot binary not found: $GODOT_BIN (set GODOT_BIN)" >&2
  exit 2
fi
if [[ ! -f "$PROJECT/project.godot" ]]; then
  echo "ERROR: no project.godot in $PROJECT" >&2
  echo "For the fixture self-test without a game project, create a minimal probe project (see README.md) and pass --project." >&2
  exit 2
fi
if [[ ${#ARGS[@]} -eq 0 ]]; then
  ARGS=(--mode game
        --out "$HOME/workspace/trap-tower/verification/touch-test-report.txt"
        --json-out "$HOME/workspace/trap-tower/verification/touch-test-report.json")
fi

exec timeout "$TIMEOUT_SECS" "$GODOT_BIN" --headless --fixed-fps 60 \
  --path "$PROJECT" -s "$SCRIPT_DIR/touch_test.gd" -- "${ARGS[@]}"
