# Linux images

| Image | Dockerfile | Purpose |
|---|---|---|
| `l2fe-verify` | `Dockerfile.verify` | Swift 6 toolchain + CMake/g++: builds the `l2encdec` helper, the Swift core, the `l2dat` CLI and the tests |
| `l2fe-tauri` | `Dockerfile.tauri` | Rust + Node + pnpm + `tauri-cli` + WebKitGTK/GTK dev packages: builds the Tauri app for Linux |

Both images are built with `docker/linux` as the build context, so no repository file or game
data ends up in a layer: the repository is bind-mounted at run time.

`scripts/verify-linux.sh` drives everything on a remote Docker host over SSH:

```sh
L2_LINUX_HOST=user@host scripts/verify-linux.sh            # sync, build images, verify
L2_LINUX_HOST=user@host scripts/verify-linux.sh --build-images-only
```

It mirrors the repository (without `.build`, `build`, `.git`, `.claude`, `node_modules`) and the
golden corpus to `~/l2file-edit-decode` on the host, then runs
`docker run --init --user <host uid>:<gid> -v ~/l2file-edit-decode:/work l2fe-verify
bash scripts/verify-linux.sh --in-container`. The container runs as the host user so every
file it writes stays owned by that user and the `_selftest-paths` permission cases are
meaningful (root ignores `chmod 000`); `--init` reaps the helper processes the stop tests orphan.
`HOME` points at `~/l2file-edit-cache/home` on the host (SwiftPM caches).

## Packaging the Tauri app

```sh
L2_LINUX_HOST=user@host scripts/make-tauri.sh --linux [--no-sync]
```

Uses the same mirror, guard and sync as `verify-linux.sh` (`scripts/lib/linux-host.sh`), then
runs four `--rm` containers named `l2fe-pkg-<phase>-<timestamp>`:

1. `l2fe-verify`: `scripts/build-l2encdec.sh` and `swift build -c release --product l2dat
   --static-swift-stdlib` (no Swift runtime libraries needed at run time), copied to
   `gui-tauri/src-tauri/binaries/{l2dat,l2encdec}-x86_64-unknown-linux-gnu` in the mirror (the
   sync leaves that directory alone);
2. `l2fe-tauri`: `pnpm install --frozen-lockfile` and `cargo tauri build --bundles appimage,deb,rpm`
   with `CARGO_HOME`, `CARGO_TARGET_DIR` and the pnpm store under `~/l2file-edit-cache`
   (`cargo`, `cargo-target-tauri`, `pnpm-store`), so a second run is incremental;
3. `l2fe-verify`: `--appimage-extract`, then `squashfs-root/AppRun --selftest` against the
   mirrored corpus and the AppImage's own `DAT_defs`, and `dpkg -c` of the `.deb`. The image
   carries the desktop libraries an AppImage leaves to the host (GL/EGL, gbm, drm, Wayland,
   X11-xcb, ALSA, HarfBuzz, FriBidi) for this; no display is needed, the self test runs before
   any window exists;
4. `fedora:40` (a public base image, pulled on first use; glibc 2.39): as root, with the mirror
   mounted read-only and no cache mount, `rpm -qpi/-qpR/-qpl` of the `.rpm` (name, licence,
   `webkit2gtk4.1` and `gtk3` requirements, `/usr/bin/l2-file-editor`, `l2dat`, `l2encdec`,
   `DAT_defs`, `.desktop`, icons), a real `dnf -y install` of it (so the dependency names are
   proven to resolve) and `l2-file-editor --selftest` from `/usr/bin`. Nothing is installed on the
   host; the container is gone afterwards.

The bundles are copied to `build/tauri/linux/`; the log is `build/linux-package.log`.

**glibc floor**: `l2encdec` is built in `l2fe-verify` (Ubuntu 24.04, GCC 13) and links glibc
dynamically, so the AppImage, the `.deb` and the `.rpm` need glibc ≥ 2.39 (Ubuntu 24.04+, Debian 13+,
Fedora 40+) even though the Tauri part is built on bookworm.

To run cargo in `l2fe-tauri` as a non-root user, give it a writable cargo home, for example
`-e CARGO_HOME=/cache/cargo` with a bind-mounted `/cache`; the preinstalled `cargo-tauri`
stays on `PATH` in `/usr/local/cargo/bin`.

Versions are `ARG`s at the top of each Dockerfile (`SWIFT_IMAGE`, `RUST_IMAGE`, `NODE_IMAGE`,
`PNPM_VERSION`, `TAURI_CLI_VERSION`).
