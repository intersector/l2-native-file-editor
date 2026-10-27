//! `--selftest <enc.dat> <ddf-dir> [--proto N]`: headless checks of the open / save pipelines.
//!
//! Runs before any window exists, on a copy of the fixture in a fresh temp folder (never next to
//! the fixtures), through the same `Session::open` / `Session::save` the commands use. Golden files
//! are found beside the fixture: `<enc>/../../txt/<stem>.txt` and `<enc>/../../dec/dec-<name>`.
//! Prints one `PASS|FAIL <check>: …` line per check; exit status 0 only when all pass.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use tokio::sync::watch;
use uuid::Uuid;

use crate::error::AppError;
use crate::runner::{self, LogSink, LogStream};
use crate::session::{OpenRequest, OpenResult, SaveRequest, Session};
use crate::tools::Tools;

const CHECKS: [&str; 5] = ["open", "save", "edit", "backup", "text"];
/// Protocol for the synthesized `L2.ini` when `--proto` is not given.
const TEXT_PROTOCOL: u16 = 413;
/// Appended to the edited cell.
const EDIT_SUFFIX: &str = " L2FE";

#[derive(Debug)]
pub struct SelftestArgs {
    pub enc: PathBuf,
    pub ddf_dir: PathBuf,
    pub protocol: Option<u16>,
}

/// Discards pipeline log lines; failures are reported through the check lines.
struct Quiet;

impl LogSink for Quiet {
    fn line(&self, _stream: LogStream, _text: &str) {}
}

/// Runs every check and returns the process exit status.
pub fn run(args: &SelftestArgs) -> i32 {
    let tools = match Tools::locate() {
        Ok(tools) => tools,
        Err(e) => {
            for check in CHECKS {
                println!("FAIL {check}: {e}");
            }
            return 1;
        }
    };
    let root = std::env::temp_dir().join(format!("l2fe-selftest-{}", Uuid::new_v4()));
    let results = tauri::async_runtime::block_on(checks(&tools, args, &root));
    let _ = fs::remove_dir_all(&root);
    let passed = results.iter().filter(|ok| **ok).count();
    println!("selftest: {passed}/{} checks passed", results.len());
    i32::from(passed != results.len())
}

/// Prints each check as it finishes; returns pass/fail per check.
async fn checks(tools: &Tools, args: &SelftestArgs, root: &Path) -> Vec<bool> {
    let mut results = Vec::new();
    let mut record = |check: &str, result: Result<String, String>| {
        match &result {
            Ok(detail) => println!("PASS {check}: {detail}"),
            Err(reason) => println!("FAIL {check}: {reason}"),
        }
        results.push(result.is_ok());
    };

    let fixture = match Fixture::prepare(args, root) {
        Ok(fixture) => fixture,
        Err(reason) => {
            for check in CHECKS {
                record(check, Err(reason.clone()));
            }
            return results;
        }
    };
    let session = Session::new(root.join("sessions"));

    // 1. open: the produced txt equals the golden txt.
    let started = Instant::now();
    let opened = session
        .open(tools, fixture.open_request(&fixture.copy, args), &Quiet)
        .await;
    let opened = match opened {
        Ok(opened) => {
            record("open", check_open(&fixture, &opened, started));
            opened
        }
        Err(e) => {
            for check in CHECKS {
                record(check, Err(format!("open failed: {e}")));
            }
            return results;
        }
    };
    let protocol = args.protocol.unwrap_or(opened.protocol);

    // 2. save of the unedited text: its decryption equals the golden decrypted dat.
    record(
        "save",
        check_unedited_save(tools, &session, &fixture, &opened, protocol).await,
    );

    // 3. edit one cell: decode + disasm differs from the golden txt only in that cell.
    record(
        "edit",
        check_edit(tools, &session, &fixture, &opened, protocol).await,
    );

    // 4. the .bak beside the saved copy holds the original bytes (kept across the second save).
    record("backup", check_backup(&fixture));

    // 5. text file round trip: open + unedited save is byte-identical.
    record(
        "text",
        check_text_round_trip(tools, &session, &fixture, args).await,
    );

    results
}

struct Fixture {
    original: PathBuf,
    copy: PathBuf,
    name: String,
    stem: String,
    golden_txt: PathBuf,
    golden_dec: PathBuf,
    ddf: PathBuf,
    work: PathBuf,
}

impl Fixture {
    fn prepare(args: &SelftestArgs, root: &Path) -> Result<Self, String> {
        let original =
            fs::canonicalize(&args.enc).map_err(|e| format!("{}: {e}", args.enc.display()))?;
        let name = original
            .file_name()
            .ok_or("the fixture has no file name")?
            .to_string_lossy()
            .into_owned();
        let stem = Path::new(&name)
            .file_stem()
            .map_or_else(|| name.clone(), |s| s.to_string_lossy().into_owned());
        let corpus = original
            .parent()
            .and_then(Path::parent)
            .ok_or("the fixture must sit in <corpus>/enc/")?;
        let work = root.join("work");
        fs::create_dir_all(&work).map_err(|e| format!("{}: {e}", work.display()))?;
        let copy = work.join(&name);
        fs::copy(&original, &copy).map_err(|e| format!("copy to {}: {e}", copy.display()))?;
        Ok(Self {
            golden_txt: corpus.join("txt").join(format!("{stem}.txt")),
            golden_dec: corpus.join("dec").join(format!("dec-{name}")),
            ddf: args.ddf_dir.join(format!("{stem}.ddf")),
            original,
            copy,
            name,
            stem,
            work,
        })
    }

    fn open_request(&self, source: &Path, args: &SelftestArgs) -> OpenRequest {
        OpenRequest {
            source: source.to_path_buf(),
            ddf_folder: args.ddf_dir.clone(),
            chronicle: args
                .ddf_dir
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            protocol: args.protocol,
        }
    }

    fn scratch(&self, file: &str) -> PathBuf {
        self.work.parent().unwrap_or(&self.work).join(file)
    }
}

fn check_open(fixture: &Fixture, opened: &OpenResult, started: Instant) -> Result<String, String> {
    let golden = read(&fixture.golden_txt)?;
    if opened.text.as_bytes() != golden.as_slice() {
        return Err(format!(
            "{}.txt differs from {} ({})",
            fixture.stem,
            fixture.golden_txt.display(),
            first_difference(opened.text.as_bytes(), &golden)
        ));
    }
    Ok(format!(
        "{}.txt byte-equal to {} ({} records, Lineage2Ver{}, {:.2} s)",
        fixture.stem,
        fixture.golden_txt.display(),
        opened.records.unwrap_or(0),
        opened.protocol,
        started.elapsed().as_secs_f64()
    ))
}

async fn check_unedited_save(
    tools: &Tools,
    session: &Session,
    fixture: &Fixture,
    opened: &OpenResult,
    protocol: u16,
) -> Result<String, String> {
    let started = Instant::now();
    save(tools, session, &opened.text, protocol).await?;
    let decoded = decode(tools, &fixture.copy, &fixture.scratch("unedited-dec.dat")).await?;
    let golden = read(&fixture.golden_dec)?;
    if decoded != golden {
        return Err(format!(
            "decode of the saved copy differs from {} ({})",
            fixture.golden_dec.display(),
            first_difference(&decoded, &golden)
        ));
    }
    Ok(format!(
        "l2dat decode of the unedited save byte-equal to {} (Lineage2Ver{protocol}, {:.2} s)",
        fixture.golden_dec.display(),
        started.elapsed().as_secs_f64()
    ))
}

async fn check_edit(
    tools: &Tools,
    session: &Session,
    fixture: &Fixture,
    opened: &OpenResult,
    protocol: u16,
) -> Result<String, String> {
    // Line 2 (the first record), cell 2 (`name` in itemname-e: a plain string).
    let (line_index, cell_index) = (1, 1);
    let mut lines: Vec<String> = opened.text.split('\n').map(str::to_owned).collect();
    let line = lines
        .get_mut(line_index)
        .ok_or("the txt has no record line")?;
    let mut cells: Vec<String> = line.split('\t').map(str::to_owned).collect();
    let cell = cells
        .get_mut(cell_index)
        .ok_or("the first record has a single cell")?;
    let before = cell.clone();
    cell.push_str(EDIT_SUFFIX);
    let after = cell.clone();
    *line = cells.join("\t");
    save(tools, session, &lines.join("\n"), protocol).await?;

    let decoded = fixture.scratch("edited-dec.dat");
    decode(tools, &fixture.copy, &decoded).await?;
    let disasm = fixture.scratch("edited.txt");
    let cmd = tools
        .l2dat()
        .arg("disasm")
        .arg("-d")
        .arg(&fixture.ddf)
        .arg(&decoded)
        .arg(&disasm);
    run_tool(&cmd).await?;
    let produced =
        String::from_utf8(read(&disasm)?).map_err(|_| "disasm output is not UTF-8".to_owned())?;
    let golden = String::from_utf8(read(&fixture.golden_txt)?)
        .map_err(|_| "golden txt is not UTF-8".to_owned())?;

    let produced: Vec<&str> = produced.split('\n').collect();
    let golden: Vec<&str> = golden.split('\n').collect();
    if produced.len() != golden.len() {
        return Err(format!(
            "line count {} differs from the golden {}",
            produced.len(),
            golden.len()
        ));
    }
    for (index, (p, g)) in produced.iter().zip(&golden).enumerate() {
        if index == line_index {
            let p_cells: Vec<&str> = p.split('\t').collect();
            let g_cells: Vec<&str> = g.split('\t').collect();
            if p_cells.len() != g_cells.len() {
                return Err(format!(
                    "line {} has {} cells, golden {}",
                    index + 1,
                    p_cells.len(),
                    g_cells.len()
                ));
            }
            for (c, (pc, gc)) in p_cells.iter().zip(&g_cells).enumerate() {
                let expected = if c == cell_index { after.as_str() } else { gc };
                if *pc != expected {
                    return Err(format!(
                        "line {}, cell {}: {pc:?}, expected {expected:?}",
                        index + 1,
                        c + 1
                    ));
                }
            }
        } else if p != g {
            return Err(format!(
                "line {} changed although it was not edited",
                index + 1
            ));
        }
    }
    Ok(format!(
        "decode + disasm differs from the golden txt only in line {}, cell {} ({before:?} -> {after:?})",
        line_index + 1,
        cell_index + 1
    ))
}

fn check_backup(fixture: &Fixture) -> Result<String, String> {
    let backup = PathBuf::from(format!("{}.bak", fixture.copy.display()));
    let saved = read(&backup)?;
    let original = read(&fixture.original)?;
    if saved != original {
        return Err(format!(
            "{} differs from the original ({})",
            backup.display(),
            first_difference(&saved, &original)
        ));
    }
    Ok(format!(
        "{}.bak holds the original bytes ({} bytes) after two saves",
        fixture.name,
        original.len()
    ))
}

async fn check_text_round_trip(
    tools: &Tools,
    session: &Session,
    fixture: &Fixture,
    args: &SelftestArgs,
) -> Result<String, String> {
    let (source, origin) = text_fixture(tools, fixture, args).await?;
    let input = read(&source)?;
    let opened = session
        .open(tools, fixture.open_request(&source, args), &Quiet)
        .await
        .map_err(|e| e.to_string())?;
    save(tools, session, &opened.text, opened.protocol).await?;
    let output = read(&source)?;
    if output != input {
        return Err(format!(
            "the unedited save of {} changed it ({})",
            origin,
            first_difference(&output, &input)
        ));
    }
    let backup = PathBuf::from(format!("{}.bak", source.display()));
    if read(&backup)? != input {
        return Err(format!(
            "{} does not hold the input bytes",
            backup.display()
        ));
    }
    Ok(format!(
        "{origin} ({}, Lineage2Ver{}): open + unedited save byte-identical ({} bytes), .bak written",
        opened.encoding.unwrap_or("?"),
        opened.protocol,
        input.len()
    ))
}

/// An `.ini`/`.int` beside the fixture, copied; else a synthesized UTF-16LE `L2.ini` encrypted by `l2dat encode`.
async fn text_fixture(
    tools: &Tools,
    fixture: &Fixture,
    args: &SelftestArgs,
) -> Result<(PathBuf, String), String> {
    let found = fixture
        .original
        .parent()
        .and_then(|dir| fs::read_dir(dir).ok())
        .and_then(|entries| {
            entries.flatten().map(|e| e.path()).find(|p| {
                p.is_file()
                    && p.extension().is_some_and(|ext| {
                        ext.eq_ignore_ascii_case("ini") || ext.eq_ignore_ascii_case("int")
                    })
            })
        });
    if let Some(found) = found {
        let name = found
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let copy = fixture.work.join(&name);
        fs::copy(&found, &copy).map_err(|e| format!("copy {}: {e}", found.display()))?;
        return Ok((copy, format!("fixture {name}")));
    }

    let text = "[URL]\r\nProtocol=lineage2\r\nServerName=L2 File Editor selftest \u{2014} \u{0395}\u{03bb}\u{03bb}\u{03b7}\u{03bd}\u{03b9}\u{03ba}\u{03ac}\r\n\r\n[Engine.Engine]\r\nGameRenderDevice=D3DDrv.D3DRenderDevice\r\n";
    let mut plain = vec![0xFF, 0xFE];
    plain.extend(text.encode_utf16().flat_map(u16::to_le_bytes));
    let decrypted = fixture.scratch("dec-L2.ini");
    fs::write(&decrypted, &plain).map_err(|e| format!("{}: {e}", decrypted.display()))?;
    let source = fixture.work.join("L2.ini");
    let protocol = args.protocol.unwrap_or(TEXT_PROTOCOL).to_string();
    let cmd = tools
        .l2dat()
        .arg("encode")
        .arg(&decrypted)
        .arg("-p")
        .arg(protocol)
        .arg("-o")
        .arg(&source)
        .arg("-f")
        .arg("L2.ini");
    run_tool(&cmd).await?;
    Ok((source, "synthesized L2.ini".to_owned()))
}

async fn save(tools: &Tools, session: &Session, text: &str, protocol: u16) -> Result<(), String> {
    let request = SaveRequest {
        text: text.to_owned(),
        protocol,
        overwrite_changed: false,
    };
    session
        .save(tools, request, &Quiet)
        .await
        .map(|_| ())
        .map_err(|e: AppError| format!("save failed: {e}"))
}

async fn decode(tools: &Tools, encrypted: &Path, output: &Path) -> Result<Vec<u8>, String> {
    run_tool(
        &tools
            .l2dat()
            .arg("decode")
            .arg(encrypted)
            .arg("-o")
            .arg(output),
    )
    .await?;
    read(output)
}

async fn run_tool(cmd: &runner::ToolCommand) -> Result<(), String> {
    let (_cancel, mut never) = watch::channel(false);
    runner::run(cmd, &Quiet, &mut never)
        .await
        .map(|_| ())
        .map_err(|e| format!("{}: {e}", cmd.display()))
}

fn read(path: &Path) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|e| format!("{}: {e}", path.display()))
}

fn first_difference(actual: &[u8], expected: &[u8]) -> String {
    match actual.iter().zip(expected).position(|(a, b)| a != b) {
        Some(offset) => format!("first difference at byte {offset}"),
        None => format!("sizes {} vs {}", actual.len(), expected.len()),
    }
}
