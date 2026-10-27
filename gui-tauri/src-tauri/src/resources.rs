//! Bundled data: the `DAT_defs` folder and `chronicles.json` (the chronicle and protocol lists).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager, Runtime};

use crate::error::AppError;

/// Chronicle folder selected when the settings name none (as in the SwiftUI app).
const DEFAULT_CHRONICLE_DIR: &str = "CT2_6";
/// Lineage2Ver selected when the settings name none (as in the SwiftUI app).
pub const DEFAULT_PROTOCOL: u16 = 413;

/// One entry of `chronicles.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Chronicle {
    pub name: String,
    #[serde(rename = "dirDDF")]
    pub dir_ddf: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChroniclesFile {
    protocols: Vec<u16>,
    default_chronicle_index: usize,
    chronicles: Vec<Chronicle>,
}

/// The resolved resource locations and lists.
#[derive(Debug, Clone)]
pub struct Resources {
    pub dat_defs: PathBuf,
    pub chronicles: Vec<Chronicle>,
    pub protocols: Vec<u16>,
    pub default_chronicle: String,
}

impl Resources {
    /// Reads the bundled resources; debug builds fall back to the repository's copy.
    pub fn load<R: Runtime>(app: &AppHandle<R>) -> Result<Self, AppError> {
        let bundled = app.path().resource_dir().ok();
        let root = [bundled, dev_root()]
            .into_iter()
            .flatten()
            .find(|dir| dir.join("chronicles.json").is_file() && dir.join("DAT_defs").is_dir())
            .ok_or_else(|| {
                AppError::Setup(
                    "The DAT_defs folder and chronicles.json are missing from the app.".into(),
                )
            })?;
        Self::from_dir(&root)
    }

    fn from_dir(root: &Path) -> Result<Self, AppError> {
        let json_path = root.join("chronicles.json");
        let bytes = std::fs::read(&json_path).map_err(AppError::io("read", &json_path))?;
        let file: ChroniclesFile = serde_json::from_slice(&bytes)
            .map_err(|e| AppError::Setup(format!("{} is not valid: {e}", json_path.display())))?;
        let default_chronicle = file
            .chronicles
            .iter()
            .find(|c| c.dir_ddf == DEFAULT_CHRONICLE_DIR)
            .or_else(|| file.chronicles.get(file.default_chronicle_index))
            .map(|c| c.dir_ddf.clone())
            .unwrap_or_default();
        Ok(Self {
            dat_defs: root.join("DAT_defs"),
            chronicles: file.chronicles,
            protocols: file.protocols,
            default_chronicle,
        })
    }

    /// `<DAT_defs>/<dir>` for a chronicle folder from the list (never an arbitrary path).
    pub fn ddf_folder(&self, chronicle_dir: &str) -> Result<PathBuf, AppError> {
        self.chronicles
            .iter()
            .find(|c| c.dir_ddf == chronicle_dir)
            .map(|c| self.dat_defs.join(&c.dir_ddf))
            .ok_or_else(|| AppError::UnknownChronicle(chronicle_dir.to_owned()))
    }
}

fn dev_root() -> Option<PathBuf> {
    if cfg!(debug_assertions) {
        Some(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Sources/L2FileEditorApp/Resources"))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repository_resources_default_to_high_five() {
        let root = dev_root().expect("debug test build");
        let resources = Resources::from_dir(&root).expect("loads");
        assert_eq!(resources.default_chronicle, "CT2_6");
        assert!(resources.protocols.contains(&DEFAULT_PROTOCOL));
        assert!(resources.ddf_folder("CT2_6").expect("listed").is_dir());
        assert!(matches!(
            resources.ddf_folder("../etc"),
            Err(AppError::UnknownChronicle(_))
        ));
    }
}
