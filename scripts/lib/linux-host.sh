# shellcheck shell=bash
# Shared remote-Docker-host helpers for scripts/verify-linux.sh and scripts/make-tauri.sh.
# Sourced, never run. The caller defines ROOT (repo root), LH_PROG (message prefix) and the
# functions die, step and usage_error (exit 64).
#
# Order of use: lh_parse_target (touches nothing on the host) -> lh_prepare_mirror (the only
# place that creates or approves the sync target) -> lh_sync / remote / lh_check_space.
# Globals set: host remote_dir_spec remote_path SSH remote_home remote_dir remote_cache qdir.

MIN_FREE_GB=15
MIRROR_MARKER=.l2fe-mirror

# Reads L2_LINUX_HOST and L2_LINUX_DIR. A '~/'-prefixed directory is relative to the remote home;
# anything else must be absolute. Nothing is resolved or created on the host here.
lh_parse_target() {
    [[ -n "${L2_LINUX_HOST:-}" ]] || usage_error "L2_LINUX_HOST is not set (e.g. L2_LINUX_HOST=user@host)"
    host="$L2_LINUX_HOST"
    remote_dir_spec="${L2_LINUX_DIR:-~/l2file-edit-decode}"
    SSH=(ssh -o BatchMode=yes "$host")
    # shellcheck disable=SC2088  # a literal '~/' prefix, resolved on the host
    case "$remote_dir_spec" in
        "~/"?*)
            remote_rel="${remote_dir_spec#\~/}"
            remote_rel="${remote_rel#"${remote_rel%%[!/]*}"}"   # '~//x' is '~/x', not '/x'
            [[ -n "$remote_rel" ]] || usage_error "L2_LINUX_DIR must name a directory below ~/ (got '$remote_dir_spec')"
            remote_path="$remote_rel" ;;
        /?*) remote_path="$remote_dir_spec" ;;
        *) usage_error "L2_LINUX_DIR must be an absolute directory below / or start with ~/ (got '$remote_dir_spec')" ;;
    esac
}

# Runs a command line on the host (already shell-quoted by the caller).
remote() { "${SSH[@]}" "$1"; }

# Refusal of a sync target: reason on stderr, exit 64 (EX_USAGE), nothing has touched the host.
refuse_target() {
    echo "$LH_PROG: refusing the sync target: $*" >&2
    exit 64
}

# Resolves the sync target, refuses anything that is not a dedicated mirror, creates or approves
# it through the marker handshake and creates the cache directory.
lh_prepare_mirror() {
    step "host $host"
    remote_home="$(remote 'cd && pwd -P')"
    # Resolve the target physically (symlinks followed, '..' and '//' collapsed) without creating
    # anything: an existing directory as is, a new one as its existing parent plus the last name.
    # (Heredocs live outside $(...): macOS bash 3.2 mis-parses them inside a command substitution.)
    local RESOLVE_SH PREPARE_SH remote_rc=0 mirror_state
    read -r -d '' RESOLVE_SH <<'REMOTE_RESOLVE' || true
cd || exit 2
p=$1
while :; do case $p in */) p=${p%/} ;; *) break ;; esac; done
[ -n "$p" ] || { echo /; exit 0; }
if [ -d "$p" ]; then
    cd -- "$p" && pwd -P
elif [ -e "$p" ] || [ -L "$p" ]; then
    exit 3
else
    parent=$(dirname -- "$p")
    [ -d "$parent" ] || exit 4
    cd -- "$parent" || exit 4
    printf '%s/%s\n' "$(pwd -P | sed 's|/*$||')" "$(basename -- "$p")"
fi
REMOTE_RESOLVE
    remote_dir="$("${SSH[@]}" "sh -s -- $(printf %q "$remote_path")" <<<"$RESOLVE_SH")" || remote_rc=$?
    case $remote_rc in
        0) ;;
        3) refuse_target "'$remote_dir_spec' exists on the host and is not a directory" ;;
        4) refuse_target "the parent directory of '$remote_dir_spec' does not exist on the host; create it first" ;;
        *) die "could not resolve '$remote_dir_spec' on the host (rc $remote_rc)" ;;
    esac
    # The directory is mirrored with --delete, so only a dedicated directory may be used: never
    # /, never $HOME or any ancestor of it, and (below) only one that is empty/new or carries the
    # marker this script created.
    [[ "$remote_dir" == /* && "${remote_dir//\//}" != "" ]] \
        || refuse_target "'$remote_dir' is the filesystem root"
    [[ "$remote_home/" != "$remote_dir/"* ]] \
        || refuse_target "'$remote_dir' is the home directory $remote_home or one of its ancestors"
    [[ "$remote_dir" != *[[:space:]]* ]] || refuse_target "remote directory must not contain whitespace: $remote_dir"
    remote_cache="$remote_home/l2file-edit-cache"
    qdir="$(printf %q "$remote_dir")"

    # Marker handshake: a directory is only ever synced with --delete when this script owns it.
    # New or empty -> create it and drop the marker. Marked -> go on. Non-empty without the marker
    # -> refuse; a mirror from before the marker existed has to be adopted once, by hand, so a
    # look-alike directory (a clone, a project folder) can never be adopted by a heuristic.
    read -r -d '' PREPARE_SH <<'REMOTE_PREPARE' || true
d=$1; m=$2
if [ -d "$d" ]; then
    if [ -f "$d/$m" ] && [ ! -L "$d/$m" ]; then echo marked; exit 0; fi
    listing=$(ls -A -- "$d") || exit 5
    if [ -z "$listing" ]; then touch -- "$d/$m" && echo adopted-empty; else echo unmarked; fi
else
    mkdir -- "$d" && touch -- "$d/$m" && echo created
fi
REMOTE_PREPARE
    mirror_state="$("${SSH[@]}" "sh -s -- $qdir $MIRROR_MARKER" <<<"$PREPARE_SH")" || die "could not prepare $remote_dir on the host"
    case "$mirror_state" in
        marked|created|adopted-empty) ;;
        unmarked)
            refuse_target "$remote_dir is not empty and has no $MIRROR_MARKER marker, so it is not a mirror this script created (rsync --delete would erase its contents). If it IS the mirror, mark it once with: ssh -o BatchMode=yes $host \"touch -- $qdir/$MIRROR_MARKER\"" ;;
        *) die "unexpected answer while preparing $remote_dir: '$mirror_state'" ;;
    esac
    remote "mkdir -p -- $(printf %q "$remote_cache/home")"
    echo "sync target: $host:$remote_dir   cache: $remote_cache"
}

lh_check_space() {
    local free
    remote 'df -h /'
    free="$(remote "df -BG --output=avail / | tail -n 1 | tr -dc 0-9")"
    [[ "$free" -ge $MIN_FREE_GB ]] || die "only ${free} GB free on the host's /, need >= $MIN_FREE_GB GB"
}

# Prints the local golden corpus: L2DAT_FIXTURES, else <repo>/fixtures/high5, else (a linked
# worktree has no game data) the main checkout's. The printed directory may not exist.
lh_fixtures_dir() {
    local fixtures common
    fixtures="${L2DAT_FIXTURES:-}"
    if [[ -z "$fixtures" ]]; then
        fixtures="$ROOT/fixtures/high5"
        if [[ ! -d "$fixtures/enc" ]]; then
            common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
            [[ -n "$common" && -d "$(dirname "$common")/fixtures/high5/enc" ]] \
                && fixtures="$(dirname "$common")/fixtures/high5"
        fi
    fi
    printf '%s\n' "$fixtures"
}

# Mirrors the repository (rsync --delete into the approved target only), then the golden corpus.
# Extra arguments go to the repository pass (e.g. more --exclude rules).
# shellcheck disable=SC2120  # the extra arguments are optional
lh_sync() {
    local fixtures need
    fixtures="$(lh_fixtures_dir)"
    for need in RESULTS.tsv enc dec txt; do
        [[ -e "$fixtures/$need" ]] || die "golden corpus incomplete: no $need in $fixtures (set L2DAT_FIXTURES)"
    done

    step "sync repo -> $host:$remote_dir"
    local RSYNC=(rsync -a --delete -e "ssh -o BatchMode=yes")
    "${RSYNC[@]}" \
        --exclude "/$MIRROR_MARKER" --exclude '/.build' --exclude '/build/' --exclude 'node_modules/' --exclude '/.claude/' \
        --exclude '/.git' --exclude '/.swiftpm/' --exclude '/fixtures/high5/' \
        --exclude 'upstream/*/build_unix/' --exclude 'upstream/*/build/' --exclude '.DS_Store' \
        "$@" "$ROOT/" "$host:$remote_dir/"
    step "sync fixtures $fixtures -> $host:$remote_dir/fixtures/high5"
    "${RSYNC[@]}" --exclude '.DS_Store' "$fixtures/" "$host:$remote_dir/fixtures/high5/"
}
