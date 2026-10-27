//! The persisted settings (`settings.json` in the app data dir, via `tauri-plugin-store`).
//!
//! The frontend owns every key through `@tauri-apps/plugin-store`; Rust only reads `tempDir`,
//! the one setting that decides where session folders go.

use std::path::PathBuf;

use tauri::{AppHandle, Manager, Runtime};
use tauri_plugin_store::StoreExt;

use crate::error::AppError;

pub const STORE_FILE: &str = "settings.json";
const TEMP_DIR_KEY: &str = "tempDir";
/// Folder created inside a user-chosen temp dir, so "inside the temp folder" never covers the user's own files.
const OVERRIDE_SUBDIR: &str = "L2FileEditor-sessions";

/// Parent of every window's session folder: the `tempDir` override, else `<app cache dir>/sessions`.
pub fn sessions_base<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, AppError> {
    let override_dir = app
        .store(STORE_FILE)
        .ok()
        .and_then(|store| store.get(TEMP_DIR_KEY))
        .and_then(|value| value.as_str().map(str::to_owned))
        .filter(|path| !path.trim().is_empty());
    match override_dir {
        Some(dir) => Ok(PathBuf::from(dir).join(OVERRIDE_SUBDIR)),
        None => app
            .path()
            .app_cache_dir()
            .map(|dir| dir.join("sessions"))
            .map_err(|e| AppError::Setup(format!("No cache folder for temp files: {e}"))),
    }
}
