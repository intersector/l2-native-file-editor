#!/usr/bin/env bash
# Build the open-l2encdec helper CLI into build/bin/l2encdec.
#
#   scripts/build-l2encdec.sh               native build via the upstream 'unix' CMake preset
#   scripts/build-l2encdec.sh --universal   macOS only: arm64 + x86_64 in build/l2encdec-universal
#
# The helper is linked statically against libl2encdec, mbedtls, miniz and blowfish, then
# stripped; the script fails unless only system libraries remain (otool -L / ldd).
# On Linux libstdc++ and libgcc are linked statically too (the helper ships inside AppImages
# that run on other distros), so only glibc stays dynamic: the minimum glibc is the build
# host's (docker/linux/Dockerfile.verify, Ubuntu 24.04: 2.39). Upstream needs GCC >= 13 (<format>).
# Runnable from any cwd; exits non-zero on any failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream/ritsuwastaken_open-l2encdec"
OUT_DIR="$ROOT/build/bin"
OUT="$OUT_DIR/l2encdec"
UNIVERSAL_BUILD_DIR="$ROOT/build/l2encdec-universal"

die() { echo "build-l2encdec: error: $*" >&2; exit 1; }

usage() {
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

universal=0
for arg in "$@"; do
    case "$arg" in
        --universal) universal=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $arg" ;;
    esac
done

os="$(uname -s)"
[[ $universal -eq 0 || "$os" == Darwin ]] || die "--universal is only supported on macOS"
command -v cmake >/dev/null || die "cmake not found (install CMake >= 3.21)"
[[ -f "$UPSTREAM/CMakePresets.json" ]] || die "upstream sources missing: $UPSTREAM"

if [[ "$os" == Darwin ]]; then
    jobs="$(sysctl -n hw.ncpu)"
else
    jobs="$(nproc)"
fi

# Static libs (no libl2encdec.dylib/.so next to the helper), no googletest download.
configure_args=(-DBUILD_SHARED_LIBS=OFF -DL2ENCDEC_BUILD_TESTS=OFF -DL2ENCDEC_BUILD_CLI=ON)
if [[ "$os" == Darwin ]]; then
    configure_args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0)
else
    configure_args+=("-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ -static-libgcc")
fi

cd "$UPSTREAM"
if [[ $universal -eq 1 ]]; then
    echo "build-l2encdec: configuring universal build in $UNIVERSAL_BUILD_DIR"
    cmake . --preset unix -B "$UNIVERSAL_BUILD_DIR" "${configure_args[@]}" \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
    cmake --build "$UNIVERSAL_BUILD_DIR" --target l2encdec_cli --parallel "$jobs"
    built="$UNIVERSAL_BUILD_DIR/cli/l2encdec"
else
    echo "build-l2encdec: configuring native build in $UPSTREAM/build_unix"
    cmake . --preset unix "${configure_args[@]}"
    cmake --build --preset unix-build --target l2encdec_cli --parallel "$jobs"
    built="$UPSTREAM/build_unix/cli/l2encdec"
fi
[[ -x "$built" ]] || die "build finished but $built is missing"

mkdir -p "$OUT_DIR"
tmp="$OUT.tmp.$$"
trap 'rm -f "$tmp"' EXIT
cp "$built" "$tmp"
strip "$tmp"
if [[ "$os" == Darwin ]]; then
    # strip invalidates the linker's ad-hoc signature; arm64 refuses to run unsigned code.
    codesign --force --sign - "$tmp"
fi
mv -f "$tmp" "$OUT"
trap - EXIT

echo "build-l2encdec: linked libraries of $OUT:"
if [[ "$os" == Darwin ]]; then
    otool -L "$OUT"
    foreign="$(otool -L "$OUT" | awk '/^\t/ { print $1 }' | grep -Ev '^/usr/lib/|^/System/Library/' || true)"
    if [[ $universal -eq 1 ]]; then
        archs="$(lipo -archs "$OUT")"
        [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || die "expected arm64 and x86_64, got: $archs"
    fi
else
    ldd "$OUT"
    foreign="$(ldd "$OUT" | awk '{ print $1 }' \
        | grep -Ev '^(linux-vdso|linux-gate|libm|libc|libpthread|libdl|librt)\.so|^/?.*ld-linux' || true)"
    deps="$(ldd "$OUT")"
    if grep -q 'not found' <<<"$deps"; then die "unresolved libraries"; fi
fi
[[ -z "$foreign" ]] || die "non-system libraries linked: $foreign"

"$OUT" -h >/dev/null || die "built helper does not run: $OUT"
echo "build-l2encdec: OK -> $OUT"
