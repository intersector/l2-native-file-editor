#!/usr/bin/env bash
# Packages the Tauri app (gui-tauri/) with the l2dat CLI, the l2encdec helper and DAT_defs bundled.
#
# usage: scripts/make-tauri.sh                                     macOS: .app + .dmg
#        L2_LINUX_HOST=user@host scripts/make-tauri.sh --linux [--no-sync]   Linux: .AppImage + .deb + .rpm
# macOS: builds the release l2dat and l2encdec, copies them to gui-tauri/src-tauri/binaries/
#   <name>-<host triple>, regenerates gui-tauri/src-tauri/icons/ from gui-tauri/icons/app-icon-1024.png,
#   runs cargo tauri build with tauri.sidecars.conf.json, signs (CODESIGN_IDENTITY, default "-" =
#   ad-hoc), copies the app and the dmg to build/tauri/macos/, launches the app once and runs its
#   --selftest with the bundled tools and DAT_defs (skipped when no golden corpus is found).
# --linux: mirrors the repo to the host like scripts/verify-linux.sh (same .l2fe-mirror guard),
#   builds l2dat + l2encdec in the l2fe-verify image, bundles in the l2fe-tauri image (cargo and
#   pnpm caches in ~/l2file-edit-cache), self-tests the AppImage headless in l2fe-verify, installs
#   the .rpm with dnf in a throwaway fedora:40 container and self-tests it there, and copies the
#   bundles to build/tauri/linux/; the log is build/linux-package.log. The bundled helper is built
#   on Ubuntu 24.04, so the packages need glibc >= 2.39 (Ubuntu 24.04+, Debian 13+, Fedora 40+).
#   --no-sync  reuse the files already on the host (skip both rsync passes)
# Environment: CARGO_TARGET_DIR and TMPDIR are respected; CODESIGN_IDENTITY; L2DAT_FIXTURES (golden
#   corpus, default <repo>/fixtures/high5, else the main checkout's); L2_LINUX_HOST, L2_LINUX_DIR
#   (see scripts/verify-linux.sh). Runnable from any cwd.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/make-tauri.sh"
TAURI_DIR="$ROOT/gui-tauri"
ICON_MASTER="$TAURI_DIR/icons/app-icon-1024.png"
# The files tauri.conf.json's bundle.icon lists, plus the default window icons.
ICON_FILES=(32x32.png 64x64.png 128x128.png 128x128@2x.png icon.icns icon.ico icon.png)
SIDECARS=(l2dat l2encdec)
SELFTEST_FIXTURE=enc/itemname-e.dat
SELFTEST_CHRONICLE=CT2_6
RPM_TEST_IMAGE=fedora:40   # glibc 2.39, the helper's floor
MIN_LOCAL_FREE_GB=2
LH_PROG=make-tauri
# shellcheck source-path=SCRIPTDIR source=lib/linux-host.sh
source "$ROOT/scripts/lib/linux-host.sh"

die() { echo "make-tauri: error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

usage() {
    sed -n '2,20p' "$SELF" | sed 's/^# \{0,1\}//'
}

# Usage errors: message and usage on stderr, exit 64 (EX_USAGE).
usage_error() {
    echo "make-tauri: $1" >&2
    usage >&2
    exit 64
}

CLEANUP=()
cleanup() { [[ ${#CLEANUP[@]} -eq 0 ]] || rm -rf "${CLEANUP[@]}"; }
trap cleanup EXIT

# run_selftest <launcher> <tool dir> <enc.dat> <ddf dir>: runs the app's --selftest with no
# L2DAT/L2ENCDEC in the environment, samples the process table while it runs and reports the
# l2dat/l2encdec processes that ran from <tool dir>. Fails unless all checks pass.
run_selftest() {
    local launcher=$1 tool_dir=$2 enc=$3 ddf=$4 out seen pid rc=0 tool
    out="$(mktemp)"; seen="$(mktemp)"
    CLEANUP+=("$out" "$seen")
    echo "selftest: $launcher --selftest $enc $ddf"
    env -u L2DAT -u L2ENCDEC "$launcher" --selftest "$enc" "$ddf" >"$out" 2>&1 &
    pid=$!
    # awk, not grep: the pattern must not appear on the sampler's own command line.
    while kill -0 "$pid" 2>/dev/null; do
        ps -e -o args= | TOOLS="$tool_dir/" awk 'index($0, ENVIRON["TOOLS"]) == 1' >>"$seen" || true
        sleep 0.02
    done
    wait "$pid" || rc=$?
    cat "$out"
    for tool in "${SIDECARS[@]}"; do
        if TOOL="$tool_dir/$tool" awk 'index($0, ENVIRON["TOOL"] " ") == 1 { found = 1 } END { exit !found }' "$seen"; then
            echo "selftest: $tool ran from $tool_dir/$tool"
        else
            echo "selftest: $tool not caught by the process sampler (finished between samples)"
        fi
    done
    if [[ $rc -ne 0 ]] || ! grep -q '^selftest: 5/5 checks passed$' "$out"; then
        die "selftest failed (exit $rc)"
    fi
}

# ---------------------------------------------------------------------------------------------
# macOS
# ---------------------------------------------------------------------------------------------
package_macos() {
    [[ "$(uname -s)" == Darwin ]] || die "the default target is macOS; on other systems use --linux"
    local tool
    for tool in swift cargo rustc pnpm codesign ditto; do
        command -v "$tool" >/dev/null || die "$tool not found"
    done
    cargo tauri --version >/dev/null 2>&1 \
        || die "tauri-cli not found: cargo install tauri-cli --version 2.12.3 --locked"
    [[ -f "$ICON_MASTER" ]] || die "icon master missing: $ICON_MASTER"

    local identity="${CODESIGN_IDENTITY:--}" hardened=true triple target_dir free_kb
    [[ "$identity" != "-" ]] || hardened=false
    triple="$(rustc -vV | sed -n 's/^host: //p')"
    [[ -n "$triple" ]] || die "could not read the host target triple from rustc -vV"
    target_dir="${CARGO_TARGET_DIR:-$TAURI_DIR/src-tauri/target}"
    mkdir -p "$target_dir"
    free_kb="$(df -Pk "$target_dir" | awk 'NR == 2 { print $4 }')"
    [[ "$free_kb" -ge $((MIN_LOCAL_FREE_GB * 1024 * 1024)) ]] \
        || die "only $((free_kb / 1024)) MiB free for $target_dir, need >= $MIN_LOCAL_FREE_GB GiB"

    step "l2dat: swift build -c release --product l2dat"
    swift build --package-path "$ROOT" -c release --product l2dat
    local bin_dir
    bin_dir="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
    [[ -x "$bin_dir/l2dat" ]] || die "missing $bin_dir/l2dat"

    step "l2encdec: scripts/build-l2encdec.sh"
    "$ROOT/scripts/build-l2encdec.sh"

    step "sidecars -> gui-tauri/src-tauri/binaries (*-$triple)"
    local binaries="$TAURI_DIR/src-tauri/binaries"
    mkdir -p "$binaries"
    install -m 755 "$bin_dir/l2dat" "$binaries/l2dat-$triple"
    install -m 755 "$ROOT/build/bin/l2encdec" "$binaries/l2encdec-$triple"
    ls -l "$binaries"

    step "icons: cargo tauri icon $ICON_MASTER"
    local icon_work f
    icon_work="$(mktemp -d)"
    CLEANUP+=("$icon_work")
    cargo tauri icon "$ICON_MASTER" -o "$icon_work"
    for f in "${ICON_FILES[@]}"; do
        [[ -f "$icon_work/$f" ]] || die "cargo tauri icon did not write $f"
        # The icns element order varies between runs; keep the committed file when its icons match.
        if [[ "$f" == *.icns && -f "$TAURI_DIR/src-tauri/icons/$f" ]] \
            && iconutil -c iconset -o "$icon_work/new.iconset" "$icon_work/$f" \
            && iconutil -c iconset -o "$icon_work/old.iconset" "$TAURI_DIR/src-tauri/icons/$f" \
            && diff -rq "$icon_work/new.iconset" "$icon_work/old.iconset" >/dev/null; then
            continue
        fi
        cp "$icon_work/$f" "$TAURI_DIR/src-tauri/icons/$f"
    done
    ls -l "$TAURI_DIR/src-tauri/icons"

    step "pnpm install --frozen-lockfile"
    (cd "$TAURI_DIR" && pnpm install --frozen-lockfile)

    step "cargo tauri build (app, dmg; signing identity '$identity')"
    local bundle_dir="$target_dir/release/bundle"
    rm -rf "$bundle_dir/macos" "$bundle_dir/dmg"
    # CI=true: the dmg is laid out without scripting Finder.
    (cd "$TAURI_DIR" && CI=true cargo tauri build \
        --config src-tauri/tauri.sidecars.conf.json \
        --config "{\"bundle\":{\"macOS\":{\"signingIdentity\":\"$identity\",\"hardenedRuntime\":$hardened}}}" \
        --bundles app,dmg)

    local app_name="L2 File Editor.app" out="$ROOT/build/tauri/macos" dmgs
    [[ -d "$bundle_dir/macos/$app_name" ]] || die "missing $bundle_dir/macos/$app_name"
    dmgs=("$bundle_dir"/dmg/*.dmg)
    [[ ${#dmgs[@]} -eq 1 && -f "${dmgs[0]}" ]] || die "expected one dmg in $bundle_dir/dmg"
    step "copy -> $out"
    rm -rf "$out"
    mkdir -p "$out"
    ditto "$bundle_dir/macos/$app_name" "$out/$app_name"
    cp "${dmgs[0]}" "$out/"
    local app="$out/$app_name" exe
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    ls -l "$app/Contents/MacOS" "$app/Contents/Resources"
    du -sh "$app" "$out"/*.dmg

    step "codesign --verify"
    for tool in "${SIDECARS[@]}"; do
        [[ -x "$app/Contents/MacOS/$tool" ]] || die "sidecar missing from the bundle: Contents/MacOS/$tool"
        codesign --verify --strict --verbose=2 "$app/Contents/MacOS/$tool"
    done
    codesign --verify --deep --strict --verbose=2 "$app"
    codesign -dv "$app" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier|CodeDirectory)'

    step "launch check"
    local exe_path="$app/Contents/MacOS/$exe" pattern pid=""
    pattern="^${exe_path//./\\.}( |\$)"
    ! pgrep -f "$pattern" >/dev/null || die "$exe_path is already running; quit it first"
    open -n "$app"
    for _ in $(seq 1 50); do
        pid="$(pgrep -f "$pattern" | head -n 1 || true)"
        [[ -z "$pid" ]] || break
        sleep 0.2
    done
    [[ -n "$pid" ]] || die "the app did not start: no process for $exe_path"
    sleep 2
    kill -0 "$pid" 2>/dev/null || die "the app exited right after launch"
    echo "launch: running as pid $pid ($exe_path)"
    kill -TERM "$pid"
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    ! kill -0 "$pid" 2>/dev/null || die "the app did not stop after SIGTERM (pid $pid)"

    step "selftest with the bundled tools and DAT_defs"
    local fixtures ddf="$app/Contents/Resources/DAT_defs/$SELFTEST_CHRONICLE"
    fixtures="$(lh_fixtures_dir)"
    [[ -d "$ddf" ]] || die "DAT_defs missing from the bundle: $ddf"
    if [[ -f "$fixtures/$SELFTEST_FIXTURE" && -d "$fixtures/txt" && -d "$fixtures/dec" ]]; then
        run_selftest "$exe_path" "$app/Contents/MacOS" "$fixtures/$SELFTEST_FIXTURE" "$ddf"
    else
        echo "make-tauri: no golden corpus at $fixtures; selftest skipped (set L2DAT_FIXTURES)"
    fi

    echo "MAKE-TAURI: OK"
    echo "$app"
    echo "$out/$(basename "${dmgs[0]}")"
}

# ---------------------------------------------------------------------------------------------
# Inside the containers (repo mirror bind-mounted at /work, caches at /cache, host uid:gid).
# ---------------------------------------------------------------------------------------------

# l2fe-verify: the Linux l2dat (Swift runtime linked statically) and l2encdec as sidecars.
container_tools() {
    cd "$ROOT"
    local triple bin_dir deps
    triple="$(uname -m)-unknown-linux-gnu"
    step "toolchain"
    swift --version 2>&1
    ldd --version | sed -n 1p

    step "l2encdec: scripts/build-l2encdec.sh"
    scripts/build-l2encdec.sh

    step "l2dat: swift build -c release --product l2dat --static-swift-stdlib"
    swift build -c release --product l2dat --static-swift-stdlib
    bin_dir="$(swift build -c release --show-bin-path)"
    strip "$bin_dir/l2dat"
    ldd "$bin_dir/l2dat"
    # Capture first: `grep -q` exits on the first match, and a pipeline whose writer then gets SIGPIPE
    # (141 under pipefail) would be inverted by `!` into a pass.
    deps="$(ldd "$bin_dir/l2dat")"
    if grep -Eq 'libswift|libFoundation|lib_Foundation|libdispatch|libBlocksRuntime|not found' <<<"$deps"; then
        die "l2dat still links the Swift runtime dynamically"
    fi

    step "sidecars -> gui-tauri/src-tauri/binaries (*-$triple)"
    mkdir -p gui-tauri/src-tauri/binaries
    install -m 755 "$bin_dir/l2dat" "gui-tauri/src-tauri/binaries/l2dat-$triple"
    install -m 755 build/bin/l2encdec "gui-tauri/src-tauri/binaries/l2encdec-$triple"
    file gui-tauri/src-tauri/binaries/*-"$triple"
    ls -l gui-tauri/src-tauri/binaries
}

# l2fe-tauri: frontend + Rust build and the AppImage/.deb/.rpm bundles, copied to build/tauri/linux.
container_bundle() {
    cd "$TAURI_DIR"
    local triple tool bundle_dir out
    triple="$(rustc -vV | sed -n 's/^host: //p')"
    for tool in "${SIDECARS[@]}"; do
        [[ -x "src-tauri/binaries/$tool-$triple" ]] || die "missing sidecar src-tauri/binaries/$tool-$triple"
    done
    step "toolchain"
    cargo tauri --version
    echo "pnpm $(pnpm --version), node $(node --version), $(rustc --version)"

    step "pnpm install --frozen-lockfile"
    mkdir -p /cache/pnpm-store
    pnpm install --frozen-lockfile --store-dir /cache/pnpm-store

    step "cargo tauri build --bundles appimage,deb,rpm"
    bundle_dir="${CARGO_TARGET_DIR:?}/release/bundle"
    rm -rf "$bundle_dir/appimage" "$bundle_dir/deb" "$bundle_dir/rpm"
    cargo tauri build --config src-tauri/tauri.sidecars.conf.json --bundles appimage,deb,rpm

    out="$ROOT/build/tauri/linux"
    rm -rf "$out"
    mkdir -p "$out"
    cp "$bundle_dir"/appimage/*.AppImage "$bundle_dir"/deb/*.deb "$bundle_dir"/rpm/*.rpm "$out/"
    ls -l "$out"
}

# l2fe-verify (glibc 2.39, the helper's floor): extract the AppImage and run its --selftest
# headless; check the .deb's file list.
container_selftest() {
    cd "$ROOT"
    local out="$ROOT/build/tauri/linux" work="$ROOT/build/tauri/linux-selftest" images debs ddf entry
    ldd --version | sed -n 1p
    images=("$out"/*.AppImage)
    debs=("$out"/*.deb)
    [[ ${#images[@]} -eq 1 && -f "${images[0]}" ]] || die "expected one AppImage in $out"
    [[ ${#debs[@]} -eq 1 && -f "${debs[0]}" ]] || die "expected one .deb in $out"

    step "AppImage --appimage-extract"
    rm -rf "$work"
    mkdir -p "$work"
    (cd "$work" && "${images[0]}" --appimage-extract >/dev/null)
    ddf="$(find "$work/squashfs-root" -type d -path "*/DAT_defs/$SELFTEST_CHRONICLE" -print -quit)"
    [[ -n "$ddf" ]] || die "DAT_defs/$SELFTEST_CHRONICLE not found in the AppImage"
    ls -l "$work/squashfs-root/usr/bin"

    step "AppImage selftest (headless)"
    run_selftest "$work/squashfs-root/AppRun" "$work/squashfs-root/usr/bin" \
        "$ROOT/fixtures/high5/$SELFTEST_FIXTURE" "$ddf"

    step "dpkg -c $(basename "${debs[0]}")"
    dpkg-deb -f "${debs[0]}" Package Version Architecture Depends
    local listing
    listing="$(dpkg -c "${debs[0]}")"
    # Entries end the line; dpkg prints them with or without a leading './'.
    for entry in usr/bin/l2dat usr/bin/l2encdec "DAT_defs/$SELFTEST_CHRONICLE/itemname-e.ddf"; do
        grep -E -- "( |\./|/)${entry//./\\.}\$" <<<"$listing" || die "the .deb has no $entry"
    done
    rm -rf "$work"
}

# fedora:40 (glibc 2.39), as root, repo mirror read-only: query the .rpm's metadata and file list,
# install it with dnf (proves the dependency names resolve) and run the installed app's --selftest.
container_rpmtest() {
    cd "$ROOT"
    local out="$ROOT/build/tauri/linux" rpms listing requires entry
    rpms=("$out"/*.rpm)
    [[ ${#rpms[@]} -eq 1 && -f "${rpms[0]}" ]] || die "expected one .rpm in $out"
    ldd --version | sed -n 1p
    ls -l "${rpms[0]}"

    step "rpm -qpi / -qpR / -qpl $(basename "${rpms[0]}")"
    rpm -qpi "${rpms[0]}"
    echo "--- requires"
    requires="$(rpm -qpR "${rpms[0]}")"
    echo "$requires"
    for entry in webkit2gtk4.1 gtk3; do
        grep -Fx -- "$entry" <<<"$requires" || die "the .rpm does not require $entry"
    done
    echo "--- files"
    listing="$(rpm -qpl "${rpms[0]}")"
    echo "$listing"
    for entry in /usr/bin/l2-file-editor /usr/bin/l2dat /usr/bin/l2encdec \
        "/usr/lib/L2 File Editor/DAT_defs/$SELFTEST_CHRONICLE/itemname-e.ddf" \
        "/usr/share/applications/L2 File Editor.desktop"; do
        grep -Fx -- "$entry" <<<"$listing" || die "the .rpm has no $entry"
    done
    grep -E '^/usr/share/icons/hicolor/.*\.png$' <<<"$listing" || die "the .rpm has no hicolor icons"

    step "dnf install $(basename "${rpms[0]}")"
    dnf -y install "${rpms[0]}"
    rpm -q l2-file-editor
    # The sampler in run_selftest needs ps; the base image may lack it (the .rpm does not need it).
    command -v ps >/dev/null || dnf -y install procps-ng

    step "installed app selftest (headless)"
    run_selftest /usr/bin/l2-file-editor /usr/bin \
        "$ROOT/fixtures/high5/$SELFTEST_FIXTURE" "/usr/lib/L2 File Editor/DAT_defs/$SELFTEST_CHRONICLE"
}

# ---------------------------------------------------------------------------------------------
# --linux, on the local machine
# ---------------------------------------------------------------------------------------------
package_linux() {
    if [[ $no_sync -eq 0 ]]; then
        # The mirror keeps its own Linux sidecars; the local (macOS) ones are not shipped.
        lh_sync --exclude '/gui-tauri/src-tauri/binaries/'
    fi

    step "host disk before"
    lh_check_space

    step "docker build l2fe-verify, l2fe-tauri (cached layers are reused)"
    remote "cd $qdir && docker build -q -t l2fe-verify -f docker/linux/Dockerfile.verify docker/linux"
    remote "cd $qdir && docker build -q -t l2fe-tauri -f docker/linux/Dockerfile.tauri docker/linux"
    remote "docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^l2fe-' || true"

    local ts qcache
    ts="$(date +%Y%m%d%H%M%S)-$$"
    qcache="$(printf %q "$remote_cache")"
    # run_container <image> <phase> [docker run options...]: --init reaps helper processes,
    # --user keeps every file in the mirror and the cache owned by the host user.
    run_container() {
        local image=$1 phase=$2
        shift 2
        step "$phase in $image (container l2fe-pkg-$phase-$ts)"
        remote "docker run --init --rm --name l2fe-pkg-$phase-$ts --user \"\$(id -u):\$(id -g)\" \
-v $qdir:/work -v $qcache:/cache -e HOME=/cache/home -w /work $* \
$image bash scripts/make-tauri.sh --in-container $phase"
    }
    run_container l2fe-verify tools
    run_container l2fe-tauri bundle -e CARGO_HOME=/cache/cargo -e CARGO_TARGET_DIR=/cache/cargo-target-tauri \
        -e APPIMAGE_EXTRACT_AND_RUN=1
    run_container l2fe-verify selftest

    # Root inside a throwaway container with the mirror mounted read-only (dnf needs root and must
    # not write root-owned files into the mirror or the cache): no cache mount, no HOME override.
    step "rpmtest in $RPM_TEST_IMAGE (container l2fe-pkg-rpmtest-$ts)"
    remote "docker run --init --rm --name l2fe-pkg-rpmtest-$ts -v $qdir:/work:ro -w /work \
$RPM_TEST_IMAGE bash scripts/make-tauri.sh --in-container rpmtest"

    local out="$ROOT/build/tauri/linux"
    step "copy bundles -> $out"
    rm -rf "$out"
    mkdir -p "$out"
    rsync -a -e "ssh -o BatchMode=yes" --include '*.AppImage' --include '*.deb' --include '*.rpm' --exclude '*' \
        "$host:$remote_dir/build/tauri/linux/" "$out/"
    ls -l "$out"
    compgen -G "$out/*.AppImage" >/dev/null || die "no AppImage copied back"
    compgen -G "$out/*.deb" >/dev/null || die "no .deb copied back"
    compgen -G "$out/*.rpm" >/dev/null || die "no .rpm copied back"

    step "host disk after"
    lh_check_space
    echo "MAKE-TAURI-LINUX: OK"
}

# ---------------------------------------------------------------------------------------------
args=("$@")
mode=macos
no_sync=0
phase=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --linux) mode=linux ;;
        --no-sync) no_sync=1 ;;
        --in-container)
            [[ $# -ge 2 ]] || usage_error "--in-container needs a phase"
            mode=container; phase=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage_error "unknown argument '$1'" ;;
    esac
    shift
done

case $mode in
    container)
        case $phase in
            tools) container_tools ;;
            bundle) container_bundle ;;
            selftest) container_selftest ;;
            rpmtest) container_rpmtest ;;
            *) usage_error "unknown container phase '$phase'" ;;
        esac
        exit 0 ;;
    macos)
        [[ $no_sync -eq 0 ]] || usage_error "--no-sync only applies to --linux"
        package_macos
        exit 0 ;;
esac

lh_parse_target

# Log the whole run; the re-executed child does the work and its exit status is kept.
LOG="$ROOT/build/linux-package.log"
if [[ -z "${L2_MAKE_TAURI_LOGGING:-}" ]]; then
    mkdir -p "$ROOT/build"
    set +e
    L2_MAKE_TAURI_LOGGING=1 "$SELF" ${args[@]+"${args[@]}"} 2>&1 | tee "$LOG"
    status=${PIPESTATUS[0]}
    echo "make-tauri: log written to $LOG (exit $status)"
    exit "$status"
fi

lh_prepare_mirror
package_linux
