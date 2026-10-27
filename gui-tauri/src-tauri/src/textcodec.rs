//! BOM-sniffed text re-encoding for decrypted `.ini` / `.int` / `.htm` files.
//!
//! This is the only content logic in the shell: `l2dat decode` produces the bytes,
//! this module turns them into editor text and back, and `l2dat encode` encrypts the result.
//! `encode(decode(bytes))` reproduces `bytes` exactly, the same contract as the Swift `TextCodec`.

use thiserror::Error;

/// Text encoding of a decrypted file, kept from open to save.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Encoding {
    /// UTF-16 little endian, optionally preceded by the `FF FE` byte-order mark.
    Utf16Le { bom: bool },
    /// UTF-8, optionally preceded by the `EF BB BF` byte-order mark.
    Utf8 { bom: bool },
    /// ISO-8859-1: fallback for 8-bit files that are not valid UTF-8.
    Latin1,
}

impl Encoding {
    /// Name shown in the status bar and log.
    pub fn title(self) -> &'static str {
        match self {
            Encoding::Utf16Le { bom: true } => "UTF-16LE (BOM)",
            Encoding::Utf16Le { bom: false } => "UTF-16LE",
            Encoding::Utf8 { bom: true } => "UTF-8 (BOM)",
            Encoding::Utf8 { bom: false } => "UTF-8",
            Encoding::Latin1 => "ISO-8859-1",
        }
    }

    fn short_name(self) -> &'static str {
        match self {
            Encoding::Utf16Le { .. } => "UTF-16LE",
            Encoding::Utf8 { .. } => "UTF-8",
            Encoding::Latin1 => "ISO-8859-1",
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum TextCodecError {
    #[error("The decrypted file is not valid {encoding} (byte offset {offset}).")]
    Malformed {
        encoding: &'static str,
        offset: usize,
    },
    #[error("The text cannot be written as {encoding}: '{ch}' at line {line}, column {column}.")]
    Unencodable {
        encoding: &'static str,
        ch: char,
        line: usize,
        column: usize,
    },
}

const UTF16_BOM: [u8; 2] = [0xFF, 0xFE];
const UTF8_BOM: [u8; 3] = [0xEF, 0xBB, 0xBF];

/// UTF-16LE BOM, UTF-8 BOM, BOM-less UTF-16LE (mostly-zero high bytes), valid UTF-8, else ISO-8859-1.
pub fn detect(bytes: &[u8]) -> Encoding {
    if bytes.starts_with(&UTF16_BOM) {
        Encoding::Utf16Le { bom: true }
    } else if bytes.starts_with(&UTF8_BOM) {
        Encoding::Utf8 { bom: true }
    } else if looks_like_utf16le(bytes) {
        Encoding::Utf16Le { bom: false }
    } else if std::str::from_utf8(bytes).is_ok() {
        Encoding::Utf8 { bom: false }
    } else {
        Encoding::Latin1
    }
}

/// Decodes `bytes` with the detected encoding.
pub fn decode(bytes: &[u8]) -> Result<(String, Encoding), TextCodecError> {
    let encoding = detect(bytes);
    let text = match encoding {
        Encoding::Utf16Le { bom } => {
            decode_utf16le(&bytes[if bom { UTF16_BOM.len() } else { 0 }..], bom)?
        }
        Encoding::Utf8 { bom } => {
            let start = if bom { UTF8_BOM.len() } else { 0 };
            std::str::from_utf8(&bytes[start..])
                .map_err(|e| TextCodecError::Malformed {
                    encoding: "UTF-8",
                    offset: start + e.valid_up_to(),
                })?
                .to_owned()
        }
        Encoding::Latin1 => bytes.iter().map(|&b| char::from(b)).collect(),
    };
    Ok((text, encoding))
}

/// Encodes `text` with `encoding`, writing its byte-order mark when it has one.
pub fn encode(text: &str, encoding: Encoding) -> Result<Vec<u8>, TextCodecError> {
    match encoding {
        Encoding::Utf16Le { bom } => {
            let mut bytes = Vec::with_capacity(text.len() * 2 + 2);
            if bom {
                bytes.extend_from_slice(&UTF16_BOM);
            }
            for unit in text.encode_utf16() {
                bytes.extend_from_slice(&unit.to_le_bytes());
            }
            Ok(bytes)
        }
        Encoding::Utf8 { bom } => {
            let mut bytes = Vec::with_capacity(text.len() + 3);
            if bom {
                bytes.extend_from_slice(&UTF8_BOM);
            }
            bytes.extend_from_slice(text.as_bytes());
            Ok(bytes)
        }
        Encoding::Latin1 => text
            .char_indices()
            .map(|(index, ch)| {
                u8::try_from(u32::from(ch)).map_err(|_| {
                    let (line, column) = line_column(text, index);
                    TextCodecError::Unencodable {
                        encoding: encoding.short_name(),
                        ch,
                        line,
                        column,
                    }
                })
            })
            .collect(),
    }
}

/// The separator the editor must join lines with to give back `text` unchanged:
/// `"\r\n"` when the text has CRLF, `"\r"` for CR-only text, `None` for LF (the editor default).
pub fn line_separator(text: &str) -> Option<&'static str> {
    if text.contains("\r\n") {
        Some("\r\n")
    } else if text.contains('\r') {
        Some("\r")
    } else {
        None
    }
}

/// 1-based line and column (in characters) of byte `index`, counting lines the way the editor splits them.
fn line_column(text: &str, index: usize) -> (usize, usize) {
    let separator = line_separator(text).unwrap_or("\n");
    let before = &text[..index];
    let line = before.matches(separator).count() + 1;
    let line_start = before.rfind(separator).map_or(0, |at| at + separator.len());
    (line, before[line_start..].chars().count() + 1)
}

/// BOM-less UTF-16LE: even length and at least half of the first 256 high bytes are zero.
fn looks_like_utf16le(bytes: &[u8]) -> bool {
    if bytes.len() < 2 || bytes.len() % 2 != 0 {
        return false;
    }
    let units = (bytes.len() / 2).min(256);
    let zero_high = (0..units).filter(|unit| bytes[2 * unit + 1] == 0).count();
    zero_high * 2 >= units
}

fn decode_utf16le(body: &[u8], bom: bool) -> Result<String, TextCodecError> {
    let start = if bom { UTF16_BOM.len() } else { 0 };
    if body.len() % 2 != 0 {
        return Err(TextCodecError::Malformed {
            encoding: "UTF-16LE",
            offset: start + body.len() - 1,
        });
    }
    let units = body
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]));
    let mut text = String::with_capacity(body.len() / 2);
    let mut unit_offset = 0;
    for decoded in char::decode_utf16(units) {
        match decoded {
            Ok(ch) => {
                unit_offset += ch.len_utf16();
                text.push(ch);
            }
            Err(_) => {
                return Err(TextCodecError::Malformed {
                    encoding: "UTF-16LE",
                    offset: start + unit_offset * 2,
                })
            }
        }
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(bytes: &[u8], expected: Encoding) {
        let (text, encoding) = decode(bytes).expect("decodes");
        assert_eq!(encoding, expected);
        assert_eq!(encode(&text, encoding).expect("encodes"), bytes);
    }

    #[test]
    fn utf16le_with_bom_round_trips() {
        let mut bytes = UTF16_BOM.to_vec();
        for unit in "[Engine]\r\nName=Ελλάδα 🜲\r\n".encode_utf16() {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        round_trip(&bytes, Encoding::Utf16Le { bom: true });
    }

    #[test]
    fn utf16le_without_bom_round_trips() {
        let bytes: Vec<u8> = "a=1\nb=2\n"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        round_trip(&bytes, Encoding::Utf16Le { bom: false });
    }

    #[test]
    fn utf8_with_and_without_bom_round_trip() {
        let mut bytes = UTF8_BOM.to_vec();
        bytes.extend_from_slice("<html>é</html>\n".as_bytes());
        round_trip(&bytes, Encoding::Utf8 { bom: true });
        round_trip("plain=ascii\r\n".as_bytes(), Encoding::Utf8 { bom: false });
    }

    #[test]
    fn latin1_round_trips_every_byte() {
        let bytes: Vec<u8> = (0x20..=0xFF).collect();
        round_trip(&bytes, Encoding::Latin1);
    }

    #[test]
    fn latin1_reports_unencodable_position() {
        let err = encode("ab\ncd\u{20AC}", Encoding::Latin1).expect_err("euro is not Latin-1");
        assert_eq!(
            err,
            TextCodecError::Unencodable {
                encoding: "ISO-8859-1",
                ch: '\u{20AC}',
                line: 2,
                column: 3
            }
        );
        let message = err.to_string();
        assert!(message.contains("line 2, column 3"), "{message}");
    }

    #[test]
    fn unpaired_surrogate_is_malformed() {
        let bytes = [0xFF, 0xFE, 0x41, 0x00, 0x00, 0xD8, 0x41, 0x00];
        assert!(matches!(
            decode(&bytes),
            Err(TextCodecError::Malformed {
                encoding: "UTF-16LE",
                offset: 4
            })
        ));
    }

    #[test]
    fn line_separator_follows_the_text() {
        assert_eq!(line_separator("a\r\nb"), Some("\r\n"));
        assert_eq!(line_separator("a\rb"), Some("\r"));
        assert_eq!(line_separator("a\nb"), None);
    }
}
