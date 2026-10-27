# L2 File Editor

A native macOS and Linux editor for Lineage II client tables (`.dat`, `.ini`, `.int`, `.htm`).

It is a from-scratch rebuild of the classic Windows tool *L2 File Editor* by Miko. It decrypts and
re-encrypts client files and converts binary `.dat` tables to tab-separated text and back, using
community DDF schemas for 54 chronicles. Its output is byte-identical to the original l2disasm/l2asm
tools on a 48-file golden corpus.

- **macOS app:** SwiftUI, macOS 14+.
- **Cross-platform app:** Tauri 2 + CodeMirror 6, packaged for macOS and Linux (AppImage, .deb, .rpm;
  glibc 2.39+: Ubuntu 24.04+, Debian 13+, Fedora 40+).
- **CLI:** `l2dat` (`decode`, `encode`, `disasm`, `asm`, `open`, `save`, `roundtrip`), portable Swift.
- **Encryption protocols:** 111, 120, 121, 211, 212, 411–414, via the bundled
  [open-l2encdec](https://github.com/ritsuwastaken/open-l2encdec) helper.

> You need your own Lineage II client files. This repository contains no game data.

## Build

Requirements: Swift 6, CMake (for the helper), and for the Tauri app Rust, Node and pnpm.

```sh
scripts/build-l2encdec.sh          # crypto helper -> build/bin/l2encdec
swift build                        # core libraries + l2dat CLI
swift run l2dat --help
swift test                         # golden tests skip without fixtures (see below)
scripts/make-app.sh                # macOS SwiftUI app -> build/L2 File Editor.app
scripts/make-tauri.sh              # Tauri app for macOS; see gui-tauri/README.md for Linux
```

Golden tests run against your own client files: put the encrypted High Five files in
`fixtures/high5/enc/` (see [`fixtures/high5/README.md`](fixtures/high5/README.md)) and run
`L2DAT_FIXTURES=$PWD/fixtures/high5 swift test`.

## Layout

- `Sources/L2Dat`: DDF schema parser and dat <-> txt conversion (portable)
- `Sources/L2Crypt`: wrapper around the `l2encdec` helper, plus ini/int/htm text codecs (portable)
- `Sources/L2DatCLI`: the `l2dat` command-line tool
- `Sources/L2FileEditorApp`: the SwiftUI macOS app and its bundled DDF schemas
- `gui-tauri/`: the cross-platform app ([README](gui-tauri/README.md));
  `docker/linux/`: Linux build and test containers ([README](docker/linux/README.md))

## Legal

This is an independent interoperability and modding tool. It is not affiliated with, endorsed by or
sponsored by NCSoft. Lineage II is a trademark of NCSoft Corporation. Use it only with client files you
are entitled to use, and respect the terms of service of any game you play. It ships no game data,
no NCSoft assets and none of the original tools' binaries.

Licensed under the [MIT License](LICENSE). Third-party components and credits:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
