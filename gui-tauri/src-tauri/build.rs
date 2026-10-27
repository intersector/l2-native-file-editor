fn main() {
    // tools.rs looks for `l2dat-<target triple>` beside the executable (Tauri's sidecar naming).
    let target = std::env::var("TARGET").expect("cargo sets TARGET for build scripts");
    println!("cargo:rustc-env=TARGET_TRIPLE={target}");
    tauri_build::build();
}
