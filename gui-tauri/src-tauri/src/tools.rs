//! Locates the `l2dat` CLI (and the `l2encdec` helper it runs).
//!
//! Search order: env `L2DAT` / `L2ENCDEC` → beside the executable (`<name>-<target triple>`,
//! then `<name>`, which is how a bundled sidecar lands in `Contents/MacOS`) → debug builds only:
//! `<repo>/.build/release/l2dat` and `<repo>/build/bin/l2encdec`.

use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::runner::ToolCommand;

const TARGET_TRIPLE: &str = env!("TARGET_TRIPLE");

/// The resolved tool paths.
#[derive(Debug, Clone)]
pub struct Tools {
    pub l2dat: PathBuf,
    /// Passed to `l2dat` as `L2ENCDEC`; when `None`, `l2dat` searches on its own.
    pub l2encdec: Option<PathBuf>,
}

#[derive(Debug, Error)]
pub enum ToolsError {
    #[error(
        "l2dat was not found (searched: {}). Set L2DAT to the l2dat executable, or build it with \
         `swift build -c release --product l2dat` in the repository.",
        .searched.join(", ")
    )]
    L2datMissing { searched: Vec<String> },
}

impl Tools {
    /// Resolves the tools once, at startup.
    pub fn locate() -> Result<Self, ToolsError> {
        let exe_dir = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(Path::to_path_buf));
        let l2dat_candidates = candidates(
            "L2DAT",
            "l2dat",
            exe_dir.as_deref(),
            dev_path(".build/release/l2dat"),
        );
        let l2dat =
            first_executable(&l2dat_candidates).ok_or_else(|| ToolsError::L2datMissing {
                searched: l2dat_candidates
                    .iter()
                    .map(|p| p.display().to_string())
                    .collect(),
            })?;
        let l2encdec = first_executable(&candidates(
            "L2ENCDEC",
            "l2encdec",
            exe_dir.as_deref(),
            dev_path("build/bin/l2encdec"),
        ));
        Ok(Self { l2dat, l2encdec })
    }

    /// An `l2dat` invocation with the helper location in its environment.
    pub fn l2dat(&self) -> ToolCommand {
        let command = ToolCommand::new(&self.l2dat);
        match &self.l2encdec {
            Some(helper) => command.env("L2ENCDEC", helper),
            None => command,
        }
    }
}

fn candidates(
    env_var: &str,
    name: &str,
    exe_dir: Option<&Path>,
    dev: Option<PathBuf>,
) -> Vec<PathBuf> {
    let mut list = Vec::new();
    if let Some(path) = std::env::var_os(env_var).filter(|v| !v.is_empty()) {
        list.push(PathBuf::from(path));
    }
    if let Some(dir) = exe_dir {
        list.push(dir.join(format!("{name}-{TARGET_TRIPLE}")));
        list.push(dir.join(name));
    }
    list.extend(dev);
    list
}

/// `<repo>/<relative>` in debug builds (repo root = `gui-tauri/..`).
fn dev_path(relative: &str) -> Option<PathBuf> {
    if cfg!(debug_assertions) {
        Some(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../..")
                .join(relative),
        )
    } else {
        None
    }
}

fn first_executable(candidates: &[PathBuf]) -> Option<PathBuf> {
    candidates.iter().find(|path| is_executable(path)).cloned()
}

fn is_executable(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.is_file() && meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        meta.is_file()
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn only_executable_files_qualify() {
        let dir = std::env::temp_dir().join(format!("l2fe-tools-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let plain = dir.join("plain");
        std::fs::write(&plain, b"").expect("write");
        assert!(!is_executable(&plain));
        assert!(!is_executable(&dir));
        assert!(is_executable(Path::new("/bin/sh")));
        assert_eq!(
            first_executable(&[plain, PathBuf::from("/bin/sh")]),
            Some(PathBuf::from("/bin/sh"))
        );
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[test]
    fn sidecar_names_carry_the_target_triple() {
        let list = candidates(
            "L2FE_TEST_UNSET_VAR",
            "l2dat",
            Some(Path::new("/app")),
            None,
        );
        assert_eq!(
            list,
            vec![
                PathBuf::from(format!("/app/l2dat-{TARGET_TRIPLE}")),
                PathBuf::from("/app/l2dat")
            ]
        );
    }
}
