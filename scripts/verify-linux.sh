#!/usr/bin/env bash
# Verifies the Swift core, the l2dat CLI and the l2encdec helper on Linux, in Docker containers
# on a remote host reached over SSH, and builds the Tauri Linux build image.
#
# usage: L2_LINUX_HOST=user@host scripts/verify-linux.sh [--build-images-only] [--no-sync] [--keep-containers]
#   --build-images-only  sync, build both images and check the tauri tools, then stop
#   --no-sync            reuse the files already on the host (skip both rsync passes)
#   --keep-containers    run the verify container without --rm (its name is printed)
# Environment:
#   L2_LINUX_HOST   required ssh destination (key auth; ssh -o BatchMode=yes)
#   L2_LINUX_DIR    sync target on the host, mirrored with rsync --delete (default ~/l2file-edit-decode);
#                   must be new/empty or hold the .l2fe-mirror marker; never / or $HOME or an ancestor
#   L2DAT_FIXTURES  local golden corpus (default <repo>/fixtures/high5, else the main checkout's)
# The full log is in build/linux-verify.log. On the host only L2_LINUX_DIR, ~/l2file-edit-cache,
# the images l2fe-verify/l2fe-tauri and containers named l2fe-* are used.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/verify-linux.sh"
LH_PROG=verify-linux
# shellcheck source-path=SCRIPTDIR source=lib/linux-host.sh
source "$ROOT/scripts/lib/linux-host.sh"
TAURI_PACKAGES=(libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev libayatana-appindicator3-dev
    patchelf file wget curl xdg-utils)

die() { echo "verify-linux: error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

usage() {
    sed -n '2,15p' "$SELF" | sed 's/^# \{0,1\}//'
}

# Usage errors: message and usage on stderr, exit 64 (EX_USAGE).
usage_error() {
    echo "verify-linux: $1" >&2
    usage >&2
    exit 64
}

# ---------------------------------------------------------------------------------------------
# Inside the l2fe-verify container (repo bind-mounted at the cwd, running as the host user).
# ---------------------------------------------------------------------------------------------
in_container() {
    cd "$ROOT"
    export L2DAT_FIXTURES="$ROOT/fixtures/high5"
    export L2ENCDEC="$ROOT/build/bin/l2encdec"

    step "toolchain"
    uname -srm
    swift --version 2>&1
    cmake --version | sed -n 1p

    step "helper: scripts/build-l2encdec.sh"
    scripts/build-l2encdec.sh
    file "$L2ENCDEC"

    step "swift build --build-tests"
    swift build --build-tests
    local bin
    bin="$(swift build --show-bin-path)"

    step "swift test (per target)"
    local listing
    listing="$(swift test list --skip-build)"
    local target expected actual out
    for target in L2DatTests L2CryptTests GoldenCorpusTests; do
        expected="$(grep -c "^$target\." <<<"$listing" || true)"
        out="$(swift test --skip-build --filter "^$target\\." 2>&1)" || { echo "$out"; die "swift test failed for $target"; }
        echo "$out" | grep -E '(✘|failed|skipped|Test run with)' || true
        actual="$(sed -nE 's/.*Test run with ([0-9]+) tests? .* passed after.*/\1/p' <<<"$out" | tail -n 1)"
        [[ -n "$actual" && "$actual" == "$expected" ]] \
            || die "$target: expected $expected tests to pass, summary says '${actual:-none}'"
        echo "verify-linux: $target $actual/$expected tests passed"
    done

    step "golden corpus: scripts/run-corpus.sh"
    out="$(scripts/run-corpus.sh 2>&1)" || { echo "$out"; die "run-corpus.sh failed"; }
    echo "$out" | tail -n 5
    local summary
    summary="$(grep -E '^summary: [0-9]+/[0-9]+ ' <<<"$out" | tail -n 1)"
    [[ "$summary" =~ ^summary:\ ([0-9]+)/([0-9]+)\  && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" \
        && "${BASH_REMATCH[1]}" -gt 0 ]] || die "corpus summary not all identical: '${summary:-none}'"

    step "debug l2dat _selftest-paths"
    "$bin/l2dat" _selftest-paths

    step "signal check: SIGINT ~50 ms into l2dat decode"
    local outdir pid rc=0 leftovers helpers
    outdir="$(mktemp -d)"
    # Job control gives the background job default SIGINT handling (non-interactive bash
    # otherwise starts background jobs with SIGINT ignored).
    set -m
    "$bin/l2dat" decode "$L2DAT_FIXTURES/enc/armorgrp.dat" -o "$outdir/armorgrp.dat" &
    pid=$!
    sleep 0.05
    kill -INT "$pid" 2>/dev/null || true
    wait "$pid" || rc=$?
    set +m
    leftovers="$(find "$outdir" -maxdepth 1 -name '.l2dat-*.tmp')"
    helpers="$(pgrep -x l2encdec || true)"
    echo "exit=$rc leftovers=[${leftovers}] l2encdec=[${helpers}]"
    [[ $rc -ne 0 ]] || die "decode finished before the signal arrived; the check proved nothing"
    [[ $rc -eq 130 ]] || die "expected exit 130 after SIGINT, got $rc"
    [[ -z "$leftovers" ]] || die "temporary files left after SIGINT: $leftovers"
    [[ -z "$helpers" ]] || die "l2encdec still running after SIGINT: $helpers"
    rm -rf "$outdir"
    echo "verify-linux: signal check OK (exit 130, no .l2dat-*.tmp, no l2encdec)"

    echo "VERIFY-LINUX-CONTAINER: OK"
}

# ---------------------------------------------------------------------------------------------
# On the local machine.
# ---------------------------------------------------------------------------------------------
args=("$@")
build_images_only=0
no_sync=0
keep_containers=0
mode=local
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-images-only) build_images_only=1 ;;
        --no-sync) no_sync=1 ;;
        --keep-containers) keep_containers=1 ;;
        --in-container) mode=container ;;
        -h|--help) usage; exit 0 ;;
        *) usage_error "unknown argument '$1'" ;;
    esac
    shift
done

if [[ $mode == container ]]; then
    in_container
    exit 0
fi

lh_parse_target

# Log the whole run; the re-executed child does the work and its exit status is kept.
LOG="$ROOT/build/linux-verify.log"
if [[ -z "${L2_VERIFY_LINUX_LOGGING:-}" ]]; then
    mkdir -p "$ROOT/build"
    set +e
    L2_VERIFY_LINUX_LOGGING=1 "$SELF" ${args[@]+"${args[@]}"} 2>&1 | tee "$LOG"
    status=${PIPESTATUS[0]}
    echo "verify-linux: log written to $LOG (exit $status)"
    exit "$status"
fi

lh_prepare_mirror

if [[ $no_sync -eq 0 ]]; then
    lh_sync
fi

step "host disk before docker build"
lh_check_space
remote 'docker system df'

step "docker build l2fe-verify"
remote "cd $qdir && docker build -t l2fe-verify -f docker/linux/Dockerfile.verify docker/linux"
step "docker build l2fe-tauri"
remote "cd $qdir && docker build -t l2fe-tauri -f docker/linux/Dockerfile.tauri docker/linux"

step "tauri image tools"
ts="$(date +%Y%m%d%H%M%S)-$$"
remote "docker run --rm --name l2fe-tauri-check-$ts l2fe-tauri bash -c \
'set -e; cargo tauri --version; echo pnpm \$(pnpm --version); echo node \$(node --version); \
dpkg-query -W -f=\"\\\${Package} \\\${Version} \\\${db:Status-Status}\\n\" ${TAURI_PACKAGES[*]}; \
missing=\$(dpkg-query -W -f=\"\\\${db:Status-Status} \\\${Package}\\n\" ${TAURI_PACKAGES[*]} | grep -v ^installed || true); \
test -z \"\$missing\" || { echo \"missing: \$missing\"; exit 1; }'"
remote "docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^l2fe-' || true"
lh_check_space

if [[ $build_images_only -eq 1 ]]; then
    echo "VERIFY-LINUX: images OK"
    exit 0
fi

name="l2fe-verify-$ts"
rm_flag=--rm
if [[ $keep_containers -eq 1 ]]; then
    rm_flag=
    echo "keeping container: $name"
fi
step "verify container $name"
# --init reaps orphaned helper processes; --user keeps every file under the target dir owned
# by the host user and keeps the _selftest-paths permission cases meaningful (not root).
remote "docker run --init $rm_flag --name $name --user \"\$(id -u):\$(id -g)\" \
-v $qdir:/work -v $(printf %q "$remote_cache"):/cache -e HOME=/cache/home -w /work \
l2fe-verify bash scripts/verify-linux.sh --in-container"

step "host disk after"
lh_check_space
echo "VERIFY-LINUX: OK"
