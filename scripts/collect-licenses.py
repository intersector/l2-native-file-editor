#!/usr/bin/env python3
"""Collect the licence texts of everything compiled into the shipped apps.

Writes licenses/THIRD_PARTY_LICENSES.txt, which make-app.sh and make-tauri.sh bundle into the apps.

Inputs (all must exist, run from any cwd):
  - the l2encdec helper's fetched C/C++ dependencies: run scripts/build-l2encdec.sh first;
  - SwiftPM checkouts: run swift build first;
  - gui-tauri/node_modules: run pnpm install in gui-tauri first;
  - cargo metadata for gui-tauri/src-tauri (downloads crate sources when missing).

Usage: python3 -I scripts/collect-licenses.py [--check]
  --check  exit 1 if the committed file is out of date instead of rewriting it.
"""

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "licenses" / "THIRD_PARTY_LICENSES.txt"
HELPER = ROOT / "upstream" / "ritsuwastaken_open-l2encdec"
HELPER_DEPS = HELPER / "build_unix" / "_deps"
TAURI = ROOT / "gui-tauri"
SPDX_DIR = ROOT / "licenses" / "spdx"
SPDX_PREFERENCE = ("MIT", "Apache-2.0", "BSD-3-Clause", "MPL-2.0")
LICENSE_PREFIXES = ("license", "licence", "copying", "notice", "unlicense")
RULE = "=" * 78


def die(message):
    print(f"collect-licenses: {message}", file=sys.stderr)
    sys.exit(1)


def read(path):
    return path.read_text(encoding="utf-8", errors="replace").strip()


def license_files(directory):
    files = [
        p for p in sorted(directory.iterdir())
        if p.is_file() and p.name.lower().startswith(LICENSE_PREFIXES)
    ]
    return files


def section(title, subtitle, texts):
    """One component: its heading line, licence summary and [(file name, text)]."""
    return title, subtitle, texts


def render(components):
    """Identical licence texts are printed once, after the list of components that use them."""
    blocks = {}
    for title, subtitle, texts in components:
        for name, text in texts:
            heading = f"{title}: {subtitle}" if subtitle else title
            blocks.setdefault(text, []).append(f"{heading} [{name}]")
    parts = []
    for text, users in blocks.items():
        parts.append("\n".join([RULE, *users, RULE, text, ""]))
    return parts


def fixed_component(title, subtitle, directory):
    if not directory.is_dir():
        die(f"missing {directory} (see the inputs in this script's header)")
    files = license_files(directory)
    if not files:
        die(f"no licence file in {directory}")
    return section(title, subtitle, [(f.name, read(f)) for f in files])


def native_sections():
    return [
        fixed_component("open-l2encdec", "MIT, https://github.com/ritsuwastaken/open-l2encdec "
                        "(the bundled l2encdec helper)", HELPER),
        fixed_component("Mbed TLS 3.6.7", "Apache-2.0 (chosen from Apache-2.0 OR GPL-2.0-or-later), "
                        "https://github.com/Mbed-TLS/mbedtls (statically linked into l2encdec)",
                        HELPER_DEPS / "mbedtls-src"),
        fixed_component("miniz 3.1.2", "MIT, https://github.com/richgel999/miniz "
                        "(statically linked into l2encdec)", HELPER_DEPS / "miniz-src"),
        fixed_component("blowfish", "MIT, https://github.com/avinal/blowfish "
                        "(statically linked into l2encdec)", HELPER_DEPS / "blowfish-src"),
        fixed_component("swift-argument-parser", "Apache-2.0, https://github.com/apple/swift-argument-parser "
                        "(linked into l2dat)", ROOT / ".build" / "checkouts" / "swift-argument-parser"),
    ]


def standard_text(pkg):
    """The SPDX text for a crate that declares a licence but ships no licence file.

    For a choice of licences ("MIT OR Apache-2.0", "MIT/Apache-2.0") the first one in SPDX_PREFERENCE is used.
    """
    expression = (pkg.get("license") or "").replace("/", " OR ")
    choices = [c.strip() for c in expression.split(" OR ") if c.strip()]
    for spdx in SPDX_PREFERENCE:
        if spdx in choices:
            holders = ", ".join(pkg.get("authors") or []) or f"the {pkg['name']} authors"
            text = read(SPDX_DIR / f"{spdx}.txt")
            note = (f"Standard {spdx} text (the crate ships no licence file). "
                    f"Copyright holders: {holders}.")
            return [(f"{spdx}.txt", f"{note}\n\n{text}")]
    return []


def rust_sections():
    raw = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--locked"],
        cwd=TAURI / "src-tauri", check=True, capture_output=True, text=True,
    ).stdout
    meta = json.loads(raw)
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = meta["resolve"]["root"]

    # Normal (non-dev, non-build) dependencies of the app, on every platform.
    seen, stack = set(), [root]
    while stack:
        node_id = stack.pop()
        for dep in nodes[node_id]["deps"]:
            kinds = {k["kind"] for k in dep["dep_kinds"]}
            if None in kinds and dep["pkg"] not in seen:
                seen.add(dep["pkg"])
                stack.append(dep["pkg"])

    sections, missing = [], []
    for pkg in sorted((packages[i] for i in seen), key=lambda p: (p["name"], p["version"])):
        directory = pathlib.Path(pkg["manifest_path"]).parent
        texts = [(f.name, read(f)) for f in license_files(directory)]
        if pkg.get("license_file"):
            extra = directory / pkg["license_file"]
            if extra.is_file() and extra.name not in {n for n, _ in texts}:
                texts.append((extra.name, read(extra)))
        if not texts:
            texts = standard_text(pkg)
        if not texts:
            missing.append(pkg)
            continue
        subtitle = ", ".join(x for x in (pkg.get("license"), pkg.get("repository")) if x)
        sections.append(section(f"{pkg['name']} {pkg['version']} (Rust crate)", subtitle, texts))
    return sections, missing


def npm_sections():
    if not (TAURI / "node_modules").is_dir():
        die("missing gui-tauri/node_modules (run pnpm install in gui-tauri)")
    raw = subprocess.run(
        ["pnpm", "licenses", "list", "--prod", "--json"],
        cwd=TAURI, check=True, capture_output=True, text=True,
    ).stdout
    entries = [e for group in json.loads(raw).values() for e in group]
    sections, missing = [], []
    for entry in sorted(entries, key=lambda e: e["name"]):
        texts = []
        for path in entry["paths"]:
            texts += [(f.name, read(f)) for f in license_files(pathlib.Path(path))]
        if not texts:
            missing.append(entry)
            continue
        version = ", ".join(entry["versions"])
        sections.append(section(f"{entry['name']} {version} (npm package)", entry["license"], texts[:1]))
    return sections, missing


def main():
    check = sys.argv[1:] == ["--check"]
    rust, rust_missing = rust_sections()
    npm, npm_missing = npm_sections()
    if rust_missing or npm_missing:
        names = [f"{p['name']} {p['version']}" for p in rust_missing] + [e["name"] for e in npm_missing]
        die("no licence file found for: " + ", ".join(names))

    header = "\n".join([
        "L2 Native File Editor: third-party licences",
        "",
        "The apps include the components below. Each is used under the licence reproduced here.",
        "The Swift runtime and Foundation (statically linked into the Linux l2dat) are Apache-2.0",
        "with the Runtime Library Exception, which requires no attribution in binaries.",
        "The bundled DDF table schemas are described in THIRD_PARTY_NOTICES.md in the source repository.",
        "Source code for the MPL-2.0 components is available unmodified from crates.io and from the",
        "repositories listed with each component.",
        "Source of this app: https://github.com/intersector/l2-native-file-editor",
        "",
        f"Native components: {len(native_sections())}, Rust crates: {len(rust)}, npm packages: {len(npm)}.",
        "Generated by scripts/collect-licenses.py; do not edit by hand.",
        "",
    ])
    text = "\n\n".join([header, *render([*native_sections(), *rust, *npm])]) + "\n"

    if check:
        if not OUT.is_file() or OUT.read_text(encoding="utf-8") != text:
            die(f"{OUT.relative_to(ROOT)} is out of date: run python3 -I scripts/collect-licenses.py")
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(rust)} Rust crates, {len(npm)} npm packages, "
          f"{len(text.encode()) // 1024} KiB")


if __name__ == "__main__":
    main()
