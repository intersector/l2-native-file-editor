//! Thin Tauri commands: resolve the window's session, call it, return typed results.

use std::path::PathBuf;

use serde::Serialize;
use tauri::{Emitter, EventTarget, Manager, State, WebviewWindow};

use crate::error::AppError;
use crate::resources::{Chronicle, DEFAULT_PROTOCOL};
use crate::runner::{LogSink, LogStream};
use crate::session::{OpenRequest, OpenResult, SaveRequest, SaveResult, SaveTxtResult};
use crate::AppState;

const APP_TITLE: &str = "L2 File Editor";

/// Forwards log lines to the window that started the job, as `log-line` events.
struct WindowLog<'a> {
    window: &'a WebviewWindow,
}

#[derive(Clone, Serialize)]
struct LogLine<'a> {
    stream: LogStream,
    text: &'a str,
}

impl LogSink for WindowLog<'_> {
    fn line(&self, stream: LogStream, text: &str) {
        let target = EventTarget::webview_window(self.window.label());
        let _ = self
            .window
            .emit_to(target, "log-line", LogLine { stream, text });
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    chronicles: Vec<Chronicle>,
    protocols: Vec<u16>,
    default_chronicle: String,
    default_protocol: u16,
    /// Why opening or saving cannot work (missing `l2dat`, missing resources); shown in the status bar.
    setup_error: Option<String>,
    l2dat: Option<String>,
    is_mac: bool,
}

#[tauri::command]
pub fn app_info(state: State<'_, AppState>) -> AppInfo {
    let resources = state.resources().ok();
    let errors: Vec<String> = [state.tools().err(), state.resources().err()]
        .into_iter()
        .flatten()
        .map(|e| e.to_string())
        .collect();
    AppInfo {
        chronicles: resources.map(|r| r.chronicles.clone()).unwrap_or_default(),
        protocols: resources
            .map(|r| r.protocols.clone())
            .unwrap_or_else(|| vec![DEFAULT_PROTOCOL]),
        default_chronicle: resources
            .map(|r| r.default_chronicle.clone())
            .unwrap_or_default(),
        default_protocol: DEFAULT_PROTOCOL,
        setup_error: (!errors.is_empty()).then(|| errors.join(" ")),
        l2dat: state.tools().ok().map(|t| t.l2dat.display().to_string()),
        is_mac: cfg!(target_os = "macos"),
    }
}

/// Files passed with `--open` or by the OS ("Open With") that the window has not opened yet.
#[tauri::command]
pub fn take_pending_opens(state: State<'_, AppState>) -> Vec<String> {
    state
        .take_pending_opens()
        .into_iter()
        .map(|p| p.display().to_string())
        .collect()
}

#[tauri::command]
pub async fn open_file(
    window: WebviewWindow,
    state: State<'_, AppState>,
    path: String,
    chronicle_dir: String,
) -> Result<OpenResult, AppError> {
    let tools = state.tools()?;
    let resources = state.resources()?;
    let session = state.session(window.app_handle(), window.label())?;
    let request = OpenRequest {
        source: PathBuf::from(path),
        ddf_folder: resources.ddf_folder(&chronicle_dir)?,
        chronicle: chronicle_dir,
        protocol: None,
    };
    let result = session
        .open(tools, request, &WindowLog { window: &window })
        .await?;
    set_title(&window, Some(&result.name), false);
    Ok(result)
}

#[tauri::command]
pub async fn save_file(
    window: WebviewWindow,
    state: State<'_, AppState>,
    text: String,
    protocol: u16,
    overwrite_changed: bool,
) -> Result<SaveResult, AppError> {
    let tools = state.tools()?;
    let session = state.session(window.app_handle(), window.label())?;
    let request = SaveRequest {
        text,
        protocol,
        overwrite_changed,
    };
    session
        .save(tools, request, &WindowLog { window: &window })
        .await
}

#[tauri::command]
pub async fn save_txt(
    window: WebviewWindow,
    state: State<'_, AppState>,
    path: String,
    text: String,
) -> Result<SaveTxtResult, AppError> {
    let session = state.session(window.app_handle(), window.label())?;
    session
        .save_txt(&PathBuf::from(path), &text, &WindowLog { window: &window })
        .await
}

/// Stops the tool the window is waiting for.
#[tauri::command]
pub fn cancel_job(window: WebviewWindow, state: State<'_, AppState>) {
    if let Some(session) = state.existing_session(window.label()) {
        session.cancel();
    }
}

/// Records unsaved edits (for the close prompt) and shows them in the window title.
#[tauri::command]
pub fn set_dirty(
    window: WebviewWindow,
    state: State<'_, AppState>,
    dirty: bool,
    name: Option<String>,
) -> Result<(), AppError> {
    state
        .session(window.app_handle(), window.label())?
        .set_dirty(dirty);
    set_title(&window, name.as_deref(), dirty);
    Ok(())
}

/// Closes the window after the frontend resolved the unsaved-edits prompt.
#[tauri::command]
pub fn close_window(window: WebviewWindow, state: State<'_, AppState>) -> Result<(), AppError> {
    if let Some(session) = state.existing_session(window.label()) {
        session.mark_closing();
    }
    window
        .destroy()
        .map_err(|e| AppError::Setup(format!("Cannot close the window: {e}")))
}

fn set_title(window: &WebviewWindow, name: Option<&str>, dirty: bool) {
    let title = match (name, dirty) {
        (Some(name), true) => format!("{name} \u{2022} edited \u{2014} {APP_TITLE}"),
        (Some(name), false) => format!("{name} \u{2014} {APP_TITLE}"),
        (None, _) => APP_TITLE.to_owned(),
    };
    let _ = window.set_title(&title);
}
