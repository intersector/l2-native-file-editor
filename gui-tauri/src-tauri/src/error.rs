//! The one error type every command returns to the window.

use std::io;
use std::path::{Path, PathBuf};

use serde::ser::{Serialize, SerializeStruct, Serializer};
use thiserror::Error;

use crate::runner::RunError;
use crate::textcodec::TextCodecError;

/// A failure shown to the user. The message is the text the status bar and log display;
/// a tool failure carries the tool's own stderr text, never a backtrace.
///
/// Serialized as `{ kind, message, position }` where `position` is `{ line, column }` when the
/// message names a text position (`line N` / `line N, column M`), for the caret jump.
#[derive(Debug, Error)]
pub enum AppError {
    #[error("{0}")]
    Setup(String),
    #[error("Another operation is still running in this window.")]
    Busy,
    #[error("No file is open.")]
    NoFile,
    #[error("{} is not a file.", .path.display())]
    NotAFile { path: PathBuf },
    #[error("Refusing to use {}: it is inside the editor's temp folder {}.", .path.display(), .temp.display())]
    InsideTemp { path: PathBuf, temp: PathBuf },
    #[error("Unknown chronicle folder '{0}'.")]
    UnknownChronicle(String),
    #[error("DDF file {ddf} not found: check DDF files in folder {}", .folder.display())]
    DdfMissing { ddf: String, folder: PathBuf },
    #[error("The export DDF {} is missing; open the file again before saving.", .path.display())]
    ExportDdfMissing { path: PathBuf },
    #[error("{} changed on disk since it was opened.", .path.display())]
    ChangedOnDisk { path: PathBuf },
    #[error("Refusing to write the text over the opened file {}; choose another name.", .path.display())]
    WouldOverwriteSource { path: PathBuf },
    #[error(transparent)]
    Tool(#[from] RunError),
    #[error(transparent)]
    Text(#[from] TextCodecError),
    #[error("{} is not valid UTF-8 text.", .path.display())]
    NotUtf8 { path: PathBuf },
    #[error("Cannot {action} {}: {source}", .path.display())]
    Io {
        action: &'static str,
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("Unexpected l2dat output (no '{expected}' line): {output}")]
    Contract {
        expected: &'static str,
        output: String,
    },
}

impl AppError {
    /// Builds an `Io` error mapper: `fs::read(p).map_err(AppError::io("read", p))`.
    pub fn io<'a>(action: &'static str, path: &'a Path) -> impl FnOnce(io::Error) -> AppError + 'a {
        move |source| AppError::Io {
            action,
            path: path.to_path_buf(),
            source,
        }
    }

    /// Stable identifier the frontend switches on.
    pub fn kind(&self) -> &'static str {
        match self {
            AppError::Setup(_) => "setup",
            AppError::Busy => "busy",
            AppError::NoFile => "noFile",
            AppError::NotAFile { .. } => "notAFile",
            AppError::InsideTemp { .. } => "insideTemp",
            AppError::UnknownChronicle(_) => "unknownChronicle",
            AppError::DdfMissing { .. } => "ddfMissing",
            AppError::ExportDdfMissing { .. } => "exportDdfMissing",
            AppError::ChangedOnDisk { .. } => "changedOnDisk",
            AppError::WouldOverwriteSource { .. } => "wouldOverwriteSource",
            AppError::Tool(RunError::Cancelled { .. }) => "cancelled",
            AppError::Tool(RunError::TimedOut { .. }) => "timedOut",
            AppError::Tool(_) => "tool",
            AppError::Text(_) => "text",
            AppError::NotUtf8 { .. } => "notUtf8",
            AppError::Io { .. } => "io",
            AppError::Contract { .. } => "contract",
        }
    }
}

/// A 1-based text position named in an error message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Position {
    pub line: u64,
    pub column: Option<u64>,
}

/// Finds the first `line N` (optionally followed by `, column M`) in `message`.
pub fn position_of(message: &str) -> Option<Position> {
    let mut rest = message;
    while let Some(at) = rest.find("line ") {
        let after = &rest[at + "line ".len()..];
        if let Some((line, tail)) = leading_number(after) {
            let column = tail
                .strip_prefix(", column ")
                .and_then(leading_number)
                .map(|(c, _)| c);
            return Some(Position { line, column });
        }
        rest = after;
    }
    None
}

fn leading_number(text: &str) -> Option<(u64, &str)> {
    let digits = text.bytes().take_while(u8::is_ascii_digit).count();
    let value = text[..digits].parse().ok()?;
    Some((value, &text[digits..]))
}

impl Serialize for AppError {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let message = self.to_string();
        let position = position_of(&message).map(|p| PositionDto {
            line: p.line,
            column: p.column,
        });
        let mut state = serializer.serialize_struct("AppError", 3)?;
        state.serialize_field("kind", self.kind())?;
        state.serialize_field("message", &message)?;
        state.serialize_field("position", &position)?;
        state.end()
    }
}

#[derive(serde::Serialize)]
struct PositionDto {
    line: u64,
    column: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_line_and_column() {
        let p = position_of("error: txt line 12, column 7, field 'name': bad value");
        assert_eq!(
            p,
            Some(Position {
                line: 12,
                column: Some(7)
            })
        );
    }

    #[test]
    fn finds_line_without_column() {
        assert_eq!(
            position_of("bad at line 3"),
            Some(Position {
                line: 3,
                column: None
            })
        );
    }

    #[test]
    fn ignores_messages_without_positions() {
        assert_eq!(position_of("dat offset 40, record 2: truncated"), None);
        assert_eq!(position_of("the line ends early"), None);
    }

    #[test]
    fn serializes_kind_message_position() {
        let err = AppError::NoFile;
        let json = serde_json::to_value(&err).expect("serializes");
        assert_eq!(json["kind"], "noFile");
        assert_eq!(json["message"], "No file is open.");
        assert!(json["position"].is_null());
    }
}
