# L2 File Editor (Tauri)

A cross-platform GUI over the `l2dat` CLI for macOS and Linux. Every `.dat` / txt transform runs
`l2dat` as a subprocess; the app only moves files, streams the tool's output into the Program Log
and shows the text in CodeMirror.

## Build caches

The commands below refer to `$CARGO_TARGET_DIR`. Export it (and optionally `TMPDIR`) before any
`swift`, `cargo` or `pnpm` command if you keep build outputs on another disk; they are deliberately
not written into any committed config:

```sh
export CARGO_TARGET_DIR="$PWD/gui-tauri/src-tauri/target"   # or any directory with a few GiB free
mkdir -p "$CARGO_TARGET_DIR"
```

To keep SwiftPM's `.build` elsewhere, symlink it at the repo root before `swift build`
(`ln -s <cache-dir>/.build .build`).

## Build the tools, then the app

```sh
swift build -c release --product l2dat      # -> .build/release/l2dat
scripts/build-l2encdec.sh                    # -> build/bin/l2encdec
cd gui-tauri
pnpm install
cargo tauri build --debug                    # tauri-cli 2.12.x: cargo install tauri-cli --version 2.12.3 --locked
```

The debug app is `$CARGO_TARGET_DIR/debug/bundle/macos/L2 File Editor.app` (the plain binary is
`$CARGO_TARGET_DIR/debug/l2-file-editor`). `pnpm tauri dev` runs it against the Vite dev server.

## Where the tools are found

1. `L2DAT` / `L2ENCDEC` environment variables;
2. beside the executable: `l2dat-<target-triple>`, then `l2dat` (a bundled sidecar lands in
   `Contents/MacOS/l2dat`); the same for `l2encdec`;
3. debug builds only: `<repo>/.build/release/l2dat` and `<repo>/build/bin/l2encdec`.

The resolved `l2encdec` is passed to `l2dat` as `L2ENCDEC`. When `l2dat` is missing, the status bar
and the log say where it was searched and how to build it.

### Bundling the tools (release packaging)

`tauri.conf.json` does not list `externalBin`, so debug builds do not need placeholder binaries.
A release build copies the tools to `src-tauri/binaries/l2dat-<triple>` and
`src-tauri/binaries/l2encdec-<triple>` (gitignored) and merges the sidecar config:

```sh
cargo tauri build --config src-tauri/tauri.sidecars.conf.json
```

## Packaging

`scripts/make-tauri.sh` does all of the above (export the cache variables first):

```sh
scripts/make-tauri.sh                                   # macOS -> build/tauri/macos/
L2_LINUX_HOST=user@host scripts/make-tauri.sh --linux    # Linux -> build/tauri/linux/
```

- **macOS**: release `l2dat` + `l2encdec` → `src-tauri/binaries/<name>-<triple>`, the icon set
  regenerated from `icons/app-icon-1024.png` with `cargo tauri icon` (only the files
  `bundle.icon` lists plus `64x64.png`/`icon.png` are kept in `src-tauri/icons/`), `pnpm install`,
  `cargo tauri build --bundles app,dmg` with the sidecar config, signed with `CODESIGN_IDENTITY`
  (default `-`, ad-hoc). Output: `build/tauri/macos/L2 File Editor.app` and the `.dmg`. The script
  then launches the app once and runs the bundled binary's `--selftest` with `L2DAT`/`L2ENCDEC`
  unset and the bundle's `Contents/Resources/DAT_defs/CT2_6` (golden corpus from `L2DAT_FIXTURES`
  or the main checkout; skipped when there is none). The tools sit in `Contents/MacOS/` without the
  triple suffix.
- **Linux** (remote Docker host, see `docker/linux/README.md`): mirrors the repo exactly like
  `scripts/verify-linux.sh` (shared code in `scripts/lib/linux-host.sh`), builds `l2dat`
  (`--static-swift-stdlib`) and `l2encdec` in `l2fe-verify`, bundles the AppImage, `.deb` and
  `.rpm` in `l2fe-tauri`, self-tests the extracted AppImage headless in `l2fe-verify`, installs
  the `.rpm` with `dnf` in a throwaway `fedora:40` container and self-tests the installed app
  there, and copies the bundles back. Log: `build/linux-package.log`. The tools land in `usr/bin/`
  beside the app binary, `DAT_defs` in `usr/lib/L2 File Editor/`. The helper is built on
  Ubuntu 24.04, so the packages need **glibc ≥ 2.39** (Ubuntu 24.04+, Debian 13+, Fedora 40+).
  The `.rpm` (built by Tauri's pure-Rust `rpm` bundler, no `rpmbuild`) requires
  `webkit2gtk4.1` and `gtk3` (`bundle.linux.rpm.depends`, added on top of the `libwebkit2gtk-4.1.so.0` / `libgtk-3.so.0` soname requirements Tauri generates itself) and is licensed
  `MIT` (`bundle.license`; the repository has no licence file of its own, only the vendored
  upstream trees do).

The SwiftUI app (`scripts/make-app.sh`) uses the same `src-tauri/icons/icon.icns`.

## Command line

```sh
l2-file-editor --open <file>                                   # open a file at launch
l2-file-editor --selftest <enc.dat> <ddf-dir> [--proto N]      # headless checks, exit 0/1
```

Self test, from the repo root (the fixtures are not committed; use a checkout that has them):

```sh
"$CARGO_TARGET_DIR/debug/l2-file-editor" --selftest fixtures/high5/enc/itemname-e.dat \
    Sources/L2FileEditorApp/Resources/DAT_defs/CT2_6
```

It works on a copy in a temp folder and prints one `PASS|FAIL` line per check: open (txt equals
`fixtures/high5/txt/<stem>.txt`), unedited save (its `l2dat decode` equals
`fixtures/high5/dec/dec-<name>`), one-cell edit (decode + disasm differs only in that cell), the
`.bak`, and a text-file round trip (an `.ini/.int` beside the fixture, else a synthesized UTF-16LE
`L2.ini` encrypted with `l2dat encode`).

## Behaviour

- **Open & Decrypt** (⌘O / Ctrl+O): `.dat` → `l2dat open` with `<DAT_defs>/<chronicle>/<stem>.ddf`
  (protocol read from the header); other files → `l2dat decode`, then BOM-sniffed text decoding.
- **Save & Encrypt** (⌘S): `.dat` → `l2dat save` with the export DDF from the open; text files are
  re-encoded with their original encoding and passed to `l2dat encode`. Both use the Lineage2Ver
  picker and `-f <original name>`. The result is staged, `<file>.bak` is written (hard link, else
  copy) and the result is renamed over the original, so the original is never missing. The first
  save after an open replaces an older `.bak`; later saves keep it (it holds the file as opened).
  A file changed on disk since the open is not replaced without asking.
- **Save TXT** (⇧⌘S): the editor text, UTF-8 for `.dat`, the original encoding for text files.
- Find / replace: ⌘F, ⌘R or ⌥⌘F; go to line: ⌘G. No word wrap.
- Closing a window (or ⌘Q) with unsaved edits asks Save / Don't Save / Cancel.

## Settings and temp files

`settings.json` in the app data folder (tauri-plugin-store): chronicle, protocol, temp folder,
system folder (Open default), TXT folder (Save TXT default), text mode and float format (stored
only: `l2dat open/save` take no such flags yet).

Each window uses `<app cache dir>/sessions/<uuid>/` (or `<temp folder>/L2FileEditor-sessions/<uuid>/`)
for `<stem>.txt`, `<stem>-new.ddf`, `dec-<name>` and the staged save; it is removed when the window
closes or the app quits. Files inside that folder are refused as inputs.

## Known gaps

- Quitting through the Dock or at logout terminates without the unsaved-edits prompt (Tauri/tao
  has no `applicationShouldTerminate` hook); running tools are still stopped and temp folders removed.
- A process killed by a signal (SIGTERM, SIGKILL, crash) leaves its session folder in the cache folder.
