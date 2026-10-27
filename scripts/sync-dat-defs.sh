#!/usr/bin/env bash
# Mirror a DAT_defs folder (one subfolder of .ddf schemas per chronicle) into the app's bundled resources.
# Usage: scripts/sync-dat-defs.sh <path/to/DAT_defs>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 1 ]] || { echo "usage: $0 <path/to/DAT_defs>" >&2; exit 2; }
SRC="${1%/}/"
DST="$ROOT/Sources/L2FileEditorApp/Resources/DAT_defs/"

if [[ ! -d "$SRC" ]]; then
    echo "error: DAT_defs not found at $SRC" >&2
    exit 1
fi

echo "Syncing $SRC -> $DST"
mkdir -p "$DST"
rsync -a --delete --exclude '.DS_Store' "$SRC" "$DST"
echo "Done: $(find "$DST" -type f -name '*.ddf' | wc -l | tr -d ' ') ddf files in $DST"
