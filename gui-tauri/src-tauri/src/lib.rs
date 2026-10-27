//! L2 File Editor: a thin GUI over the `l2dat` CLI.
//!
//! Launch modes: `--selftest <enc.dat> <ddf-dir> [--proto N]` runs headless checks before any
//! window exists and exits; otherwise the Tauri app starts, opening `--open <path>` if given.

mod commands;
mod error;
mod resources;
mod runner;
mod selftest;
mod session;
mod settings;
mod textcodec;
mod tools;

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use tauri::{AppHandle, Emitter, EventTarget, Manager, RunEvent, Runtime, Window, WindowEvent};

use crate::error::AppError;
use crate::resources::Resources;
use crate::selftest::SelftestArgs;
use crate::session::Session;
use crate::tools::Tools;

/// How long the app waits at exit for running tools to stop and temp folders to go.
const EXIT_CLEANUP_LIMIT: Duration = Duration::from_secs(5);
#[cfg(target_os = "macos")]
const QUIT_MENU_ID: &str = "l2fe-quit";

/// State shared by every command.
pub struct AppState {
    tools: Result<Tools, String>,
    resources: OnceLock<Result<Resources, String>>,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    pending_opens: Mutex<Vec<PathBuf>>,
}

impl AppState {
    fn new(tools: Result<Tools, String>, pending_opens: Vec<PathBuf>) -> Self {
        Self {
            tools,
            resources: OnceLock::new(),
            sessions: Mutex::new(HashMap::new()),
            pending_opens: Mutex::new(pending_opens),
        }
    }

    pub fn tools(&self) -> Result<&Tools, AppError> {
        self.tools.as_ref().map_err(|e| AppError::Setup(e.clone()))
    }

    pub fn resources(&self) -> Result<&Resources, AppError> {
        match self.resources.get() {
            Some(Ok(resources)) => Ok(resources),
            Some(Err(e)) => Err(AppError::Setup(e.clone())),
            None => Err(AppError::Setup("The app is still starting.".into())),
        }
    }

    /// The window's session, created on first use under the configured temp folder.
    pub fn session<R: Runtime>(
        &self,
        app: &AppHandle<R>,
        label: &str,
    ) -> Result<Arc<Session>, AppError> {
        let mut sessions = self.sessions();
        if let Some(session) = sessions.get(label) {
            return Ok(Arc::clone(session));
        }
        let session = Arc::new(Session::new(settings::sessions_base(app)?));
        sessions.insert(label.to_owned(), Arc::clone(&session));
        Ok(session)
    }

    pub fn existing_session(&self, label: &str) -> Option<Arc<Session>> {
        self.sessions().get(label).cloned()
    }

    pub fn take_pending_opens(&self) -> Vec<PathBuf> {
        std::mem::take(&mut *self.pending_opens.lock().unwrap_or_else(|e| e.into_inner()))
    }

    fn push_pending_opens(&self, paths: impl IntoIterator<Item = PathBuf>) {
        self.pending_opens
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .extend(paths);
    }

    fn sessions(&self) -> MutexGuard<'_, HashMap<String, Arc<Session>>> {
        self.sessions.lock().unwrap_or_else(|e| e.into_inner())
    }
}

enum Launch {
    Selftest(SelftestArgs),
    Gui { open: Vec<PathBuf> },
}

const USAGE: &str = "usage: l2-file-editor [--open <file>]\n       \
                     l2-file-editor --selftest <enc.dat> <ddf-dir> [--proto N]";

/// Unknown arguments are ignored (macOS may pass `-psn_…`).
fn parse_args(args: impl IntoIterator<Item = OsString>) -> Result<Launch, String> {
    let mut args = args.into_iter();
    let mut open = Vec::new();
    while let Some(arg) = args.next() {
        if arg == "--selftest" {
            let enc = args.next().ok_or(USAGE)?;
            let ddf_dir = args.next().ok_or(USAGE)?;
            let mut protocol = None;
            while let Some(extra) = args.next() {
                if extra == "--proto" {
                    let value = args.next().ok_or(USAGE)?;
                    protocol = Some(value.to_string_lossy().parse().map_err(|_| USAGE)?);
                } else {
                    return Err(USAGE.into());
                }
            }
            return Ok(Launch::Selftest(SelftestArgs {
                enc: enc.into(),
                ddf_dir: ddf_dir.into(),
                protocol,
            }));
        } else if arg == "--open" {
            open.push(PathBuf::from(args.next().ok_or(USAGE)?));
        }
    }
    Ok(Launch::Gui { open })
}

pub fn run() {
    let open = match parse_args(std::env::args_os().skip(1)) {
        Ok(Launch::Selftest(args)) => std::process::exit(selftest::run(&args)),
        Ok(Launch::Gui { open }) => open,
        Err(usage) => {
            eprintln!("{usage}");
            std::process::exit(2);
        }
    };
    let state = AppState::new(Tools::locate().map_err(|e| e.to_string()), open);

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_store::Builder::new().build())
        .manage(state)
        .setup(|app| {
            let resources = Resources::load(app.handle()).map_err(|e| e.to_string());
            let _ = app.state::<AppState>().resources.set(resources);
            #[cfg(target_os = "macos")]
            app.set_menu(mac_menu(app.handle())?)?;
            Ok(())
        })
        .on_menu_event(|_app, _event| {
            #[cfg(target_os = "macos")]
            if _event.id() == QUIT_MENU_ID {
                // Close every window the normal way, so unsaved edits get their prompt.
                for window in _app.webview_windows().values() {
                    let _ = window.close();
                }
            }
        })
        .on_window_event(on_window_event)
        .invoke_handler(tauri::generate_handler![
            commands::app_info,
            commands::take_pending_opens,
            commands::open_file,
            commands::save_file,
            commands::save_txt,
            commands::cancel_job,
            commands::set_dirty,
            commands::close_window,
        ])
        .build(tauri::generate_context!())
        .expect("failed to build the L2 File Editor app");

    app.run(|handle, event| match event {
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        RunEvent::Opened { urls } => {
            let paths: Vec<PathBuf> = urls
                .iter()
                .filter_map(|url| url.to_file_path().ok())
                .collect();
            if !paths.is_empty() {
                handle.state::<AppState>().push_pending_opens(paths);
                let _ = handle.emit("pending-opens", ());
            }
        }
        RunEvent::Exit => shutdown_sessions(handle),
        _ => {}
    });
}

fn on_window_event<R: Runtime>(window: &Window<R>, event: &WindowEvent) {
    let state = window.state::<AppState>();
    match event {
        WindowEvent::CloseRequested { api, .. } => {
            if let Some(session) = state.existing_session(window.label()) {
                if session.is_dirty() && !session.is_closing() {
                    api.prevent_close();
                    let target = EventTarget::webview_window(window.label());
                    let _ = window.emit_to(target, "close-requested", ());
                }
            }
        }
        WindowEvent::Destroyed => {
            if let Some(session) = state.existing_session(window.label()) {
                let app = window.app_handle().clone();
                let label = window.label().to_owned();
                tauri::async_runtime::spawn(async move {
                    session.shutdown().await;
                    app.state::<AppState>().sessions().remove(&label);
                });
            }
        }
        _ => {}
    }
}

/// Stops every running tool and removes every session folder before the process exits.
fn shutdown_sessions<R: Runtime>(app: &AppHandle<R>) {
    let sessions: Vec<Arc<Session>> = app
        .state::<AppState>()
        .sessions()
        .values()
        .cloned()
        .collect();
    for session in &sessions {
        session.mark_closing();
        session.cancel();
    }
    tauri::async_runtime::block_on(async {
        let all = async {
            for session in &sessions {
                session.shutdown().await;
            }
        };
        let _ = tokio::time::timeout(EXIT_CLEANUP_LIMIT, all).await;
    });
}

/// The standard macOS menu, with a Quit item that closes windows (and so asks about unsaved edits)
/// instead of terminating the process directly.
#[cfg(target_os = "macos")]
fn mac_menu<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<tauri::menu::Menu<R>> {
    use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
    let quit = MenuItemBuilder::with_id(QUIT_MENU_ID, "Quit L2 File Editor")
        .accelerator("CmdOrCtrl+Q")
        .build(app)?;
    let app_menu = SubmenuBuilder::new(app, "L2 File Editor")
        .about(None)
        .separator()
        .services()
        .separator()
        .hide()
        .hide_others()
        .show_all()
        .separator()
        .item(&quit)
        .build()?;
    let edit = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;
    let window = SubmenuBuilder::new(app, "Window")
        .minimize()
        .maximize()
        .separator()
        .close_window()
        .build()?;
    MenuBuilder::new(app)
        .items(&[&app_menu, &edit, &window])
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Launch, String> {
        parse_args(args.iter().map(OsString::from))
    }

    #[test]
    fn parses_open_and_ignores_unknown_arguments() {
        let Ok(Launch::Gui { open }) = parse(&["-psn_0_123", "--open", "/a b/x.dat"]) else {
            panic!("gui")
        };
        assert_eq!(open, vec![PathBuf::from("/a b/x.dat")]);
    }

    #[test]
    fn parses_selftest_with_protocol() {
        let Ok(Launch::Selftest(args)) = parse(&["--selftest", "e.dat", "defs", "--proto", "413"])
        else {
            panic!("selftest")
        };
        assert_eq!(args.enc, PathBuf::from("e.dat"));
        assert_eq!(args.ddf_dir, PathBuf::from("defs"));
        assert_eq!(args.protocol, Some(413));
        assert!(parse(&["--selftest", "e.dat"]).is_err());
        assert!(parse(&["--selftest", "e.dat", "defs", "--proto", "x"]).is_err());
    }
}
