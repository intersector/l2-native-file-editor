//! One window's document: its temp folder, the opened file, and the open / save pipelines.
//!
//! Every dat/txt transform is an `l2dat` subprocess. This module only moves files,
//! reads the CLI's stdout contract lines (`opened …`, `saved …`, `decoded …`, `encoded …`) and,
//! for `.ini/.int/.htm`, re-encodes text through [`textcodec`].
//!
//! Temp layout: `<sessions base>/<uuid>/` holds `<stem>.txt`, `<stem>-new.ddf` (the export DDF
//! that `l2dat save` reads), `dec-<name>` for text files, and the staged `<name>` during a save.

use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

use serde::Serialize;
use tokio::sync::{watch, Mutex};
use uuid::Uuid;

use crate::error::AppError;
use crate::runner::{self, LogSink, LogStream, ToolCommand, ToolOutput};
use crate::textcodec::{self, Encoding};
use crate::tools::Tools;

/// What Open & Decrypt needs.
#[derive(Debug, Clone)]
pub struct OpenRequest {
    pub source: PathBuf,
    /// The chronicle folder holding `<stem>.ddf`.
    pub ddf_folder: PathBuf,
    /// Chronicle folder name, for the log.
    pub chronicle: String,
    /// `-p` for `l2dat`; `None` lets it read the protocol from the file header.
    pub protocol: Option<u16>,
}

/// What Save & Encrypt needs.
#[derive(Debug, Clone)]
pub struct SaveRequest {
    pub text: String,
    pub protocol: u16,
    /// Replace the file even though it changed on disk since it was opened.
    pub overwrite_changed: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenResult {
    pub path: String,
    pub name: String,
    pub text: String,
    /// Separator the editor must join lines with to keep the text byte-exact (`None` = LF).
    pub line_separator: Option<&'static str>,
    pub protocol: u16,
    /// Record count of a `.dat` (from `l2dat open`); `None` for text files.
    pub records: Option<u64>,
    /// Encoding title of a text file; `None` for `.dat`.
    pub encoding: Option<&'static str>,
    pub elapsed_ms: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveResult {
    pub path: String,
    pub protocol: u16,
    /// Rows written (from `l2dat save`); `None` for text files.
    pub rows: Option<u64>,
    pub backup: String,
    /// The existing `.bak` was kept because this window already saved the file since opening it.
    pub backup_kept: bool,
    pub elapsed_ms: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveTxtResult {
    pub path: String,
    pub bytes: u64,
    pub encoding: &'static str,
}

#[derive(Debug, Clone)]
enum FileKind {
    Dat {
        txt: PathBuf,
        export_ddf: PathBuf,
    },
    Text {
        encoding: Encoding,
        decrypted: PathBuf,
    },
}

/// Size and modification time, to notice a file replaced behind the editor's back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    len: u64,
    modified: Option<SystemTime>,
}

impl Stamp {
    fn of(path: &Path) -> std::io::Result<Self> {
        let meta = fs::metadata(path)?;
        Ok(Self {
            len: meta.len(),
            modified: meta.modified().ok(),
        })
    }
}

#[derive(Debug, Clone)]
struct OpenedFile {
    source: PathBuf,
    name: String,
    kind: FileKind,
    protocol: u16,
    stamp: Stamp,
}

#[derive(Debug, Default)]
struct Doc {
    opened: Option<OpenedFile>,
    /// This window already saved the opened file: an existing `.bak` is kept on later saves.
    saved_since_open: bool,
}

/// Outcome of replacing the destination.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Backup {
    Written,
    Kept,
    /// The destination did not exist, so there was nothing to back up.
    None,
}

/// A window's document state. The document lock is also the busy guard: one job at a time.
pub struct Session {
    base: PathBuf,
    dir: PathBuf,
    doc: Mutex<Doc>,
    cancel: watch::Sender<bool>,
    dirty: AtomicBool,
    closing: AtomicBool,
}

impl Session {
    /// A session whose folder will be `<base>/<uuid>` (created on first use).
    pub fn new(base: PathBuf) -> Self {
        let dir = base.join(Uuid::new_v4().to_string());
        Self {
            base,
            dir,
            doc: Mutex::new(Doc::default()),
            cancel: watch::channel(false).0,
            dirty: AtomicBool::new(false),
            closing: AtomicBool::new(false),
        }
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty.load(Ordering::SeqCst)
    }

    pub fn set_dirty(&self, dirty: bool) {
        self.dirty.store(dirty, Ordering::SeqCst);
    }

    pub fn is_closing(&self) -> bool {
        self.closing.load(Ordering::SeqCst)
    }

    pub fn mark_closing(&self) {
        self.closing.store(true, Ordering::SeqCst);
    }

    /// Stops the running tool, if any (its job then fails with "cancelled").
    pub fn cancel(&self) {
        self.cancel.send_replace(true);
    }

    /// Cancels any job, waits for it to settle, and removes this session's folder (only `<base>/<uuid>`).
    pub async fn shutdown(&self) {
        self.mark_closing();
        self.cancel();
        let _doc = self.doc.lock().await;
        if self.dir.is_dir() {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    /// Open & Decrypt: `l2dat open` for `.dat`, `l2dat decode` + text decoding for anything else.
    pub async fn open(
        &self,
        tools: &Tools,
        request: OpenRequest,
        sink: &dyn LogSink,
    ) -> Result<OpenResult, AppError> {
        let mut doc = self.doc.try_lock().map_err(|_| AppError::Busy)?;
        let mut cancel = self.begin_job()?;
        let started = Instant::now();
        let (file, text, records) = framed(
            sink,
            "Open & Decode",
            self.open_steps(tools, &request, sink, &mut cancel),
        )
        .await?;
        let result = OpenResult {
            path: file.source.display().to_string(),
            name: file.name.clone(),
            line_separator: textcodec::line_separator(&text),
            text,
            protocol: file.protocol,
            records,
            encoding: match file.kind {
                FileKind::Text { encoding, .. } => Some(encoding.title()),
                FileKind::Dat { .. } => None,
            },
            elapsed_ms: millis(started.elapsed()),
        };
        doc.opened = Some(file);
        doc.saved_since_open = false;
        self.set_dirty(false);
        Ok(result)
    }

    async fn open_steps(
        &self,
        tools: &Tools,
        request: &OpenRequest,
        sink: &dyn LogSink,
        cancel: &mut watch::Receiver<bool>,
    ) -> Result<(OpenedFile, String, Option<u64>), AppError> {
        let source =
            fs::canonicalize(&request.source).map_err(AppError::io("open", &request.source))?;
        if !source.is_file() {
            return Err(AppError::NotAFile { path: source });
        }
        fs::create_dir_all(&self.dir).map_err(AppError::io("create", &self.dir))?;
        let base = fs::canonicalize(&self.base).map_err(AppError::io("open", &self.base))?;
        if source.starts_with(&base) {
            return Err(AppError::InsideTemp {
                path: source,
                temp: base,
            });
        }
        let stamp = Stamp::of(&source).map_err(AppError::io("read", &source))?;
        let name = file_name(&source);
        let stem = Path::new(&name)
            .file_stem()
            .map_or_else(|| name.clone(), |s| s.to_string_lossy().into_owned());
        sink.line(
            LogStream::Info,
            &format!("|  {}  [chronicle {}]", source.display(), request.chronicle),
        );

        if is_dat(&source) {
            let ddf = locate_ddf(&request.ddf_folder, &stem)?;
            sink.line(LogStream::Info, &format!("|  ddf {}", ddf.display()));
            let txt = self.dir.join(format!("{stem}.txt"));
            let export_ddf = self.dir.join(format!("{stem}-new.ddf"));
            let mut cmd = tools.l2dat().arg("open").arg(&source).arg("-d").arg(&ddf);
            if let Some(protocol) = request.protocol {
                cmd = cmd.arg("-p").arg(protocol.to_string());
            }
            cmd = cmd.arg("-o").arg(&txt).arg("-e").arg(&export_ddf);
            let out = tool(cmd, sink, cancel).await?;
            let line = contract_line(&out.stdout, "opened ")?;
            let (protocol, records) = parse_protocol(line)
                .zip(parse_records(line))
                .ok_or_else(|| contract_error("opened ", &out.stdout))?;
            let text = String::from_utf8(fs::read(&txt).map_err(AppError::io("read", &txt))?)
                .map_err(|_| AppError::NotUtf8 { path: txt.clone() })?;
            let file = OpenedFile {
                source,
                name,
                kind: FileKind::Dat { txt, export_ddf },
                protocol,
                stamp,
            };
            Ok((file, text, Some(records)))
        } else {
            let decrypted = self.dir.join(format!("dec-{name}"));
            let mut cmd = tools
                .l2dat()
                .arg("decode")
                .arg(&source)
                .arg("-o")
                .arg(&decrypted);
            if let Some(protocol) = request.protocol {
                cmd = cmd.arg("-p").arg(protocol.to_string());
            }
            let out = tool(cmd, sink, cancel).await?;
            let protocol = contract_line(&out.stdout, "decoded ")
                .ok()
                .and_then(parse_protocol)
                .ok_or_else(|| contract_error("decoded ", &out.stdout))?;
            let bytes = fs::read(&decrypted).map_err(AppError::io("read", &decrypted))?;
            let (text, encoding) = textcodec::decode(&bytes)?;
            sink.line(
                LogStream::Info,
                &format!(
                    "|  text {}, {} characters",
                    encoding.title(),
                    text.chars().count()
                ),
            );
            let file = OpenedFile {
                source,
                name,
                kind: FileKind::Text {
                    encoding,
                    decrypted,
                },
                protocol,
                stamp,
            };
            Ok((file, text, None))
        }
    }

    /// Save & Encrypt: `l2dat save` (or text encoding + `l2dat encode`) into the session folder,
    /// then `<file>.bak` and an atomic replace of the original.
    pub async fn save(
        &self,
        tools: &Tools,
        request: SaveRequest,
        sink: &dyn LogSink,
    ) -> Result<SaveResult, AppError> {
        let mut doc = self.doc.try_lock().map_err(|_| AppError::Busy)?;
        let opened = doc.opened.clone().ok_or(AppError::NoFile)?;
        let mut cancel = self.begin_job()?;
        let keep_backup = doc.saved_since_open;
        let started = Instant::now();
        let (rows, backup, stamp) = framed(
            sink,
            "Save & Encode",
            self.save_steps(tools, &opened, &request, keep_backup, sink, &mut cancel),
        )
        .await?;
        if let Some(file) = doc.opened.as_mut() {
            file.stamp = stamp;
            file.protocol = request.protocol;
        }
        doc.saved_since_open = true;
        Ok(SaveResult {
            path: opened.source.display().to_string(),
            protocol: request.protocol,
            rows,
            backup: backup_path(&opened.source).display().to_string(),
            backup_kept: backup == Backup::Kept,
            elapsed_ms: millis(started.elapsed()),
        })
    }

    async fn save_steps(
        &self,
        tools: &Tools,
        opened: &OpenedFile,
        request: &SaveRequest,
        keep_backup: bool,
        sink: &dyn LogSink,
        cancel: &mut watch::Receiver<bool>,
    ) -> Result<(Option<u64>, Backup, Stamp), AppError> {
        let protocol = request.protocol.to_string();
        sink.line(
            LogStream::Info,
            &format!("|  {}  [Lineage2Ver{protocol}]", opened.source.display()),
        );
        check_stamp(opened, request.overwrite_changed)?;
        fs::create_dir_all(&self.dir).map_err(AppError::io("create", &self.dir))?;
        let staged = self.dir.join(&opened.name);
        let rows = match &opened.kind {
            FileKind::Dat { txt, export_ddf } => {
                if !export_ddf.is_file() {
                    return Err(AppError::ExportDdfMissing {
                        path: export_ddf.clone(),
                    });
                }
                fs::write(txt, request.text.as_bytes()).map_err(AppError::io("write", txt))?;
                let cmd = tools
                    .l2dat()
                    .arg("save")
                    .arg(txt)
                    .arg("-d")
                    .arg(export_ddf)
                    .arg("-p")
                    .arg(&protocol)
                    .arg("-o")
                    .arg(&staged)
                    .arg("-f")
                    .arg(&opened.name);
                let out = tool(cmd, sink, cancel).await?;
                let rows = contract_line(&out.stdout, "saved ")
                    .ok()
                    .and_then(parse_rows)
                    .ok_or_else(|| contract_error("saved ", &out.stdout))?;
                Some(rows)
            }
            FileKind::Text {
                encoding,
                decrypted,
            } => {
                let bytes = textcodec::encode(&request.text, *encoding)?;
                fs::write(decrypted, &bytes).map_err(AppError::io("write", decrypted))?;
                sink.line(
                    LogStream::Info,
                    &format!("|  text {}, {} bytes", encoding.title(), bytes.len()),
                );
                let cmd = tools
                    .l2dat()
                    .arg("encode")
                    .arg(decrypted)
                    .arg("-p")
                    .arg(&protocol)
                    .arg("-o")
                    .arg(&staged)
                    .arg("-f")
                    .arg(&opened.name);
                let out = tool(cmd, sink, cancel).await?;
                contract_line(&out.stdout, "encoded ")?;
                None
            }
        };
        // The tool took a while: look again right before replacing the file.
        check_stamp(opened, request.overwrite_changed)?;
        // A `.bak` from an earlier save only stands for "the file as opened" while nobody else
        // has written the file since; a changed file being replaced gets its own fresh backup.
        let unchanged_since_last_save =
            Stamp::of(&opened.source).is_ok_and(|now| now == opened.stamp);
        let backup = commit_into_place(
            &staged,
            &opened.source,
            keep_backup && unchanged_since_last_save,
        )?;
        let _ = fs::remove_file(&staged);
        let backup_note = match backup {
            Backup::Written => format!("backup {}", file_name(&backup_path(&opened.source))),
            Backup::Kept => format!(
                "backup {} kept (the file as opened)",
                file_name(&backup_path(&opened.source))
            ),
            Backup::None => "no backup (the file did not exist)".to_owned(),
        };
        sink.line(
            LogStream::Info,
            &format!("|  {backup_note}, saved {}", opened.source.display()),
        );
        let stamp = Stamp::of(&opened.source).map_err(AppError::io("read", &opened.source))?;
        Ok((rows, backup, stamp))
    }

    /// Save TXT: the editor text as UTF-8 for a `.dat`, in the original encoding for a text file.
    pub async fn save_txt(
        &self,
        path: &Path,
        text: &str,
        sink: &dyn LogSink,
    ) -> Result<SaveTxtResult, AppError> {
        let doc = self.doc.try_lock().map_err(|_| AppError::Busy)?;
        framed(sink, "Save TXT", async {
            let encoding = match doc.opened.as_ref().map(|f| &f.kind) {
                Some(FileKind::Text { encoding, .. }) => *encoding,
                _ => Encoding::Utf8 { bom: false },
            };
            if let Some(opened) = &doc.opened {
                if fs::canonicalize(path).is_ok_and(|p| p == opened.source) {
                    return Err(AppError::WouldOverwriteSource {
                        path: opened.source.clone(),
                    });
                }
            }
            let bytes = textcodec::encode(text, encoding)?;
            write_replacing(path, &bytes)?;
            sink.line(
                LogStream::Info,
                &format!(
                    "|  {} ({}, {} bytes)",
                    path.display(),
                    encoding.title(),
                    bytes.len()
                ),
            );
            Ok(SaveTxtResult {
                path: path.display().to_string(),
                bytes: bytes.len() as u64,
                encoding: encoding.title(),
            })
        })
        .await
    }

    fn begin_job(&self) -> Result<watch::Receiver<bool>, AppError> {
        if self.is_closing() {
            return Err(AppError::Busy);
        }
        self.cancel.send_replace(false);
        Ok(self.cancel.subscribe())
    }
}

/// Logs `======== <title> {` … `}` around a pipeline, with its total time or its error.
async fn framed<T>(
    sink: &dyn LogSink,
    title: &str,
    work: impl Future<Output = Result<T, AppError>>,
) -> Result<T, AppError> {
    let started = Instant::now();
    sink.line(LogStream::Info, &format!("======== {title} {{"));
    let result = work.await;
    match &result {
        Ok(_) => sink.line(
            LogStream::Info,
            &format!("}} {}", seconds(started.elapsed())),
        ),
        Err(error) => {
            sink.line(LogStream::Error, &format!("|  failed: {error}"));
            sink.line(
                LogStream::Error,
                &format!("}} failed after {}", seconds(started.elapsed())),
            );
        }
    }
    result
}

async fn tool(
    cmd: ToolCommand,
    sink: &dyn LogSink,
    cancel: &mut watch::Receiver<bool>,
) -> Result<ToolOutput, AppError> {
    sink.line(LogStream::Info, &format!("|  {}", cmd.display()));
    let out = runner::run(&cmd, sink, cancel).await?;
    sink.line(
        LogStream::Info,
        &format!("|  {} ok ({})", cmd.name(), seconds(out.elapsed)),
    );
    Ok(out)
}

fn check_stamp(opened: &OpenedFile, overwrite_changed: bool) -> Result<(), AppError> {
    let unchanged = Stamp::of(&opened.source).is_ok_and(|now| now == opened.stamp);
    if unchanged || overwrite_changed {
        Ok(())
    } else {
        Err(AppError::ChangedOnDisk {
            path: opened.source.clone(),
        })
    }
}

/// Puts `staged` at `dest` without ever leaving `dest` missing.
///
/// 1. copy `staged` to a hidden sibling of `dest` (works across volumes), with `dest`'s permissions, fsync;
/// 2. unless an existing `.bak` is to be kept: hard-link `dest` (copy when linking fails) to a hidden
///    sibling and rename it over `<dest>.bak`;
/// 3. rename the sibling over `dest`.
///
/// Temp siblings are removed on any error; `dest` and an existing `.bak` stay as they were.
pub(crate) fn commit_into_place(
    staged: &Path,
    dest: &Path,
    keep_existing_backup: bool,
) -> Result<Backup, AppError> {
    let dir = dest
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let name = file_name(dest);
    let token = Uuid::new_v4().simple().to_string();
    let tmp = dir.join(format!(".{name}.l2fe-{token}.tmp"));
    let bak = backup_path(dest);
    let bak_tmp = dir.join(format!(".{name}.bak.l2fe-{token}.tmp"));

    let result = (|| {
        let existing = fs::metadata(dest).ok();
        if existing
            .as_ref()
            .is_some_and(|meta| meta.permissions().readonly())
        {
            let denied = std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "the file is read-only",
            );
            return Err(AppError::Io {
                action: "replace",
                path: dest.to_path_buf(),
                source: denied,
            });
        }
        fs::copy(staged, &tmp).map_err(AppError::io("write", &tmp))?;
        if let Some(meta) = &existing {
            fs::set_permissions(&tmp, meta.permissions())
                .map_err(AppError::io("set permissions on", &tmp))?;
        }
        fs::File::open(&tmp)
            .and_then(|file| file.sync_all())
            .map_err(AppError::io("flush", &tmp))?;
        let backup = if existing.is_none() {
            Backup::None
        } else if keep_existing_backup && bak.is_file() {
            Backup::Kept
        } else {
            if fs::hard_link(dest, &bak_tmp).is_err() {
                fs::copy(dest, &bak_tmp).map_err(AppError::io("back up", dest))?;
            }
            fs::rename(&bak_tmp, &bak).map_err(AppError::io("write", &bak))?;
            Backup::Written
        };
        fs::rename(&tmp, dest).map_err(AppError::io("replace", dest))?;
        Ok(backup)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
        let _ = fs::remove_file(&bak_tmp);
    }
    result
}

/// Writes `bytes` to `path` through a hidden sibling and a rename.
fn write_replacing(path: &Path, bytes: &[u8]) -> Result<(), AppError> {
    let dir = path
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let tmp = dir.join(format!(
        ".{}.l2fe-{}.tmp",
        file_name(path),
        Uuid::new_v4().simple()
    ));
    let result = fs::write(&tmp, bytes)
        .map_err(AppError::io("write", &tmp))
        .and_then(|()| fs::rename(&tmp, path).map_err(AppError::io("replace", path)));
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn backup_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(".bak");
    PathBuf::from(name)
}

fn file_name(path: &Path) -> String {
    path.file_name().map_or_else(
        || path.display().to_string(),
        |n| n.to_string_lossy().into_owned(),
    )
}

fn is_dat(path: &Path) -> bool {
    path.extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("dat"))
}

/// `<folder>/<stem>.ddf`, matched case-insensitively when the exact name is missing.
fn locate_ddf(folder: &Path, stem: &str) -> Result<PathBuf, AppError> {
    let ddf = format!("{stem}.ddf");
    let direct = folder.join(&ddf);
    if direct.is_file() {
        return Ok(direct);
    }
    let lowered = ddf.to_lowercase();
    fs::read_dir(folder)
        .ok()
        .and_then(|entries| {
            entries
                .flatten()
                .map(|e| e.path())
                .find(|p| p.is_file() && file_name(p).to_lowercase() == lowered)
        })
        .ok_or_else(|| AppError::DdfMissing {
            ddf,
            folder: folder.to_path_buf(),
        })
}

/// The last stdout line starting with `prefix` (the CLI's result line).
fn contract_line<'a>(stdout: &'a [String], prefix: &'static str) -> Result<&'a str, AppError> {
    stdout
        .iter()
        .rev()
        .find(|line| line.starts_with(prefix))
        .map(String::as_str)
        .ok_or_else(|| contract_error(prefix, stdout))
}

fn contract_error(expected: &'static str, stdout: &[String]) -> AppError {
    AppError::Contract {
        expected: expected.trim_end(),
        output: stdout.join(" | "),
    }
}

/// The part before ` -> <output path>`.
fn head(line: &str) -> &str {
    line.rfind(" -> ").map_or(line, |at| &line[..at])
}

/// `NNN` from `… (Lineage2VerNNN) …`.
fn parse_protocol(line: &str) -> Option<u16> {
    let head = head(line);
    let at = head.rfind("(Lineage2Ver")? + "(Lineage2Ver".len();
    leading_number(&head[at..])
}

/// `N` from `opened <in> (Lineage2VerNNN): N records -> <out>`.
fn parse_records(line: &str) -> Option<u64> {
    let head = head(line);
    let at = head.rfind("): ")? + "): ".len();
    head[at..].strip_suffix(" records").and_then(leading_number)
}

/// `N` from `saved N rows (Lineage2VerNNN) -> <out>`.
fn parse_rows(line: &str) -> Option<u64> {
    line.strip_prefix("saved ").and_then(leading_number)
}

fn leading_number<T: std::str::FromStr>(text: &str) -> Option<T> {
    let digits = text.bytes().take_while(u8::is_ascii_digit).count();
    text[..digits].parse().ok()
}

fn seconds(elapsed: Duration) -> String {
    format!("{:.2} s", elapsed.as_secs_f64())
}

fn millis(elapsed: Duration) -> u64 {
    u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("l2fe-{label} ü-{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).expect("mkdir");
        dir
    }

    #[test]
    fn parses_the_cli_result_lines() {
        let opened =
            "opened /a (b)/itemname-e.dat (Lineage2Ver413): 19197 records -> /t/itemname-e.txt";
        assert_eq!(parse_protocol(opened), Some(413));
        assert_eq!(parse_records(opened), Some(19197));
        let saved = "saved 19197 rows (Lineage2Ver121) -> /t/x.dat";
        assert_eq!(parse_rows(saved), Some(19197));
        assert_eq!(parse_protocol(saved), Some(121));
        assert_eq!(
            parse_protocol("decoded /a/L2.ini (Lineage2Ver413) -> /t/dec-L2.ini"),
            Some(413)
        );
        assert_eq!(
            parse_protocol("decoded /a/L2.ini -> /t/(Lineage2Ver999)"),
            None
        );
        let stdout = vec!["warning: x".to_owned(), saved.to_owned()];
        assert_eq!(contract_line(&stdout, "saved ").expect("found"), saved);
        assert!(matches!(
            contract_line(&stdout, "opened "),
            Err(AppError::Contract { .. })
        ));
    }

    #[test]
    fn first_save_writes_backup_and_replaces() {
        let dir = temp_dir("commit");
        let dest = dir.join("item name.dat");
        let staged = dir.join("staged");
        fs::write(&dest, b"original").expect("write");
        fs::write(&staged, b"new").expect("write");
        fs::write(backup_path(&dest), b"stale backup").expect("write");
        assert_eq!(
            commit_into_place(&staged, &dest, false).expect("commits"),
            Backup::Written
        );
        assert_eq!(fs::read(&dest).expect("read"), b"new");
        assert_eq!(fs::read(backup_path(&dest)).expect("read"), b"original");
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .expect("list")
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "temp siblings left behind");
        fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[test]
    fn later_save_keeps_the_backup_of_the_file_as_opened() {
        let dir = temp_dir("keep");
        let dest = dir.join("a.dat");
        let staged = dir.join("staged");
        fs::write(&dest, b"first save").expect("write");
        fs::write(backup_path(&dest), b"as opened").expect("write");
        fs::write(&staged, b"second save").expect("write");
        assert_eq!(
            commit_into_place(&staged, &dest, true).expect("commits"),
            Backup::Kept
        );
        assert_eq!(fs::read(backup_path(&dest)).expect("read"), b"as opened");
        assert_eq!(fs::read(&dest).expect("read"), b"second save");
        fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[test]
    fn missing_destination_is_created_without_backup() {
        let dir = temp_dir("create");
        let dest = dir.join("new.dat");
        let staged = dir.join("staged");
        fs::write(&staged, b"x").expect("write");
        assert_eq!(
            commit_into_place(&staged, &dest, false).expect("commits"),
            Backup::None
        );
        assert!(!backup_path(&dest).exists());
        fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[cfg(unix)]
    #[test]
    fn read_only_destination_or_folder_leaves_the_original_intact() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("readonly");
        let dest = dir.join("a.dat");
        let staged = dir.join("staged");
        fs::write(&dest, b"original").expect("write");
        fs::write(&staged, b"new").expect("write");

        fs::set_permissions(&dest, fs::Permissions::from_mode(0o444)).expect("chmod");
        assert!(matches!(
            commit_into_place(&staged, &dest, false),
            Err(AppError::Io {
                action: "replace",
                ..
            })
        ));
        assert_eq!(fs::read(&dest).expect("read"), b"original");
        fs::set_permissions(&dest, fs::Permissions::from_mode(0o644)).expect("chmod");

        let sub = dir.join("locked");
        fs::create_dir(&sub).expect("mkdir");
        let locked = sub.join("b.dat");
        fs::write(&locked, b"original").expect("write");
        fs::set_permissions(&sub, fs::Permissions::from_mode(0o555)).expect("chmod");
        assert!(commit_into_place(&staged, &locked, false).is_err());
        assert_eq!(fs::read(&locked).expect("read"), b"original");
        assert_eq!(
            fs::read_dir(&sub).expect("list").count(),
            1,
            "nothing written into a read-only folder"
        );
        fs::set_permissions(&sub, fs::Permissions::from_mode(0o755)).expect("chmod");
        fs::remove_dir_all(&dir).expect("cleanup");
    }

    struct Quiet;

    impl LogSink for Quiet {
        fn line(&self, _stream: LogStream, _text: &str) {}
    }

    /// A stand-in `l2dat`: `decode` / `encode` copy their input to `-o` and print the contract line.
    #[cfg(unix)]
    fn fake_tools(dir: &Path) -> Tools {
        use std::os::unix::fs::PermissionsExt;
        let script = dir.join("fake-l2dat");
        fs::write(
            &script,
            "#!/bin/sh\ncmd=$1; src=$2; shift 2\nwhile [ $# -gt 0 ]; do\n  case \"$1\" in -o) out=$2; shift 2;; *) shift;; esac\ndone\ncp \"$src\" \"$out\"\ncase $cmd in\n  decode) echo \"decoded $src (Lineage2Ver413) -> $out\";;\n  encode) echo \"encoded $src -> $out\";;\nesac\n",
        )
        .expect("write");
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).expect("chmod");
        Tools {
            l2dat: script,
            l2encdec: None,
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn replacing_a_file_changed_on_disk_backs_up_the_external_version() {
        let dir = temp_dir("external");
        let tools = fake_tools(&dir);
        let source = dir.join("a.ini");
        let bak = backup_path(&source);
        fs::write(&source, b"original").expect("write");
        let session = Session::new(dir.join("sessions"));
        let open = OpenRequest {
            source: source.clone(),
            ddf_folder: dir.clone(),
            chronicle: "test".to_owned(),
            protocol: None,
        };
        session.open(&tools, open, &Quiet).await.expect("opens");
        let save = |text: &str, overwrite_changed: bool| SaveRequest {
            text: text.to_owned(),
            protocol: 413,
            overwrite_changed,
        };

        let first = session
            .save(&tools, save("first edit", false), &Quiet)
            .await
            .expect("first save");
        assert!(!first.backup_kept);
        assert_eq!(fs::read(&bak).expect("read"), b"original");

        // Another program writes the file; a plain save refuses and touches nothing.
        fs::write(&source, b"EXTERNAL EDIT").expect("write");
        let refused = session
            .save(&tools, save("second edit", false), &Quiet)
            .await;
        assert!(matches!(refused, Err(AppError::ChangedOnDisk { .. })));
        assert_eq!(fs::read(&source).expect("read"), b"EXTERNAL EDIT");
        assert_eq!(fs::read(&bak).expect("read"), b"original");

        // Replace: the external version must land in the .bak before it is overwritten.
        let second = session
            .save(&tools, save("second edit", true), &Quiet)
            .await
            .expect("replace save");
        assert!(!second.backup_kept, "the external version was backed up");
        assert_eq!(fs::read(&bak).expect("read"), b"EXTERNAL EDIT");
        assert_eq!(fs::read(&source).expect("read"), b"second edit");

        // Unchanged since that save: the .bak is kept, not rewritten.
        let third = session
            .save(&tools, save("third edit", false), &Quiet)
            .await
            .expect("third save");
        assert!(third.backup_kept);
        assert_eq!(fs::read(&bak).expect("read"), b"EXTERNAL EDIT");
        assert_eq!(fs::read(&source).expect("read"), b"third edit");

        session.shutdown().await;
        fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[test]
    fn ddf_lookup_is_case_insensitive_and_names_the_folder() {
        let dir = temp_dir("ddf");
        fs::write(dir.join("ItemName-e.ddf"), b"").expect("write");
        // On a case-insensitive volume the exact path already resolves; elsewhere the scan finds it.
        let found = locate_ddf(&dir, "itemname-e").expect("found");
        assert!(found.is_file());
        assert_eq!(file_name(&found).to_lowercase(), "itemname-e.ddf");
        let err = locate_ddf(&dir, "skillgrp").expect_err("missing");
        assert!(
            err.to_string().contains("check DDF files in folder"),
            "{err}"
        );
        fs::remove_dir_all(&dir).expect("cleanup");
    }
}
