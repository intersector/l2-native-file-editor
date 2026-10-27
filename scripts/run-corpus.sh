#!/usr/bin/env bash
# Runs the golden-corpus check (`l2dat corpus`) in release mode with the repo defaults.
#
# usage: scripts/run-corpus.sh [--fixtures DIR] [--ddf DIR]
#   --fixtures DIR  corpus with RESULTS.tsv, enc/, dec/, txt/, ddf/
#                   (default: $L2DAT_FIXTURES or <repo>/fixtures/high5)
#   --ddf DIR       DDFs the corpus was made with
#                   (default: <repo>/Sources/L2FileEditorApp/Resources/DAT_defs/CT2_6)
# Option values may not start with '-' (write ./-dir for such a directory).
# The l2encdec helper is taken from $L2ENCDEC, else <repo>/build/bin/l2encdec
# (build it with scripts/build-l2encdec.sh).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="${L2DAT_FIXTURES:-$repo/fixtures/high5}"
ddf="$repo/Sources/L2FileEditorApp/Resources/DAT_defs/CT2_6"

usage() {
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

# Usage errors: message and usage on stderr, exit 64 (EX_USAGE).
usage_error() {
    echo "run-corpus.sh: $1" >&2
    usage >&2
    exit 64
}

# An option's value must be present, non-empty and not another option.
has_value() {
    [[ $# -ge 2 && -n "$2" && "$2" != -* ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fixtures) has_value "$@" || usage_error "--fixtures needs a directory"; fixtures="$2"; shift 2 ;;
        --ddf) has_value "$@" || usage_error "--ddf needs a directory"; ddf="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage_error "unknown argument '$1'" ;;
    esac
done

if [[ ! -f "$fixtures/RESULTS.tsv" ]]; then
    echo "run-corpus.sh: no RESULTS.tsv in $fixtures (set L2DAT_FIXTURES or pass --fixtures)" >&2
    exit 1
fi
if [[ -z "${L2ENCDEC:-}" && -x "$repo/build/bin/l2encdec" ]]; then
    export L2ENCDEC="$repo/build/bin/l2encdec"
fi

exec swift run -c release --package-path "$repo" l2dat corpus --fixtures "$fixtures" --ddf "$ddf"
