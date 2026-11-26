#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh debug
bundle="$PWD/dist/kbd-display Debug.app"
# LaunchServices reuses the old executable and drops launch arguments on reopen.
# Restart just this checkout's debug process when iterating.
while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid"
    for ((attempt = 0; attempt < 30; attempt++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "Previous debug process is still exiting." >&2
        exit 1
    fi
done < <(ps -axo pid=,comm= | awk -v exe="$bundle/Contents/MacOS/kbd-display" '{ pid=$1; sub(/^ *[0-9]+ +/, ""); if ($0 == exe) print pid }')
open "$bundle" --args "$@"
