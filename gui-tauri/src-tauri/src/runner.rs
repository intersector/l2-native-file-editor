//! The only place that spawns, signals and reaps tool processes.
//!
//! Each tool runs in its own process group (`process_group(0)`), so a timeout, a cancel or a
//! dropped future stops the tool and every helper it started (`l2dat` runs `l2encdec`).
//! stdout and stderr are pumped line by line into a [`LogSink`] while the tool runs.

use std::collections::VecDeque;
use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use serde::Serialize;
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncRead, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::watch;

/// Per-call limit unless the command sets its own.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);
/// stderr lines kept for the error message.
const STDERR_TAIL: usize = 40;
/// Time between SIGTERM (l2dat removes its temp files) and SIGKILL.
const TERM_GRACE: Duration = Duration::from_secs(2);

/// Where a log line came from. The runner produces `Stdout`/`Stderr`; pipelines add `Info`/`Error`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LogStream {
    Stdout,
    Stderr,
    Info,
    Error,
}

/// Receives log lines as they are produced.
pub trait LogSink: Send + Sync {
    fn line(&self, stream: LogStream, text: &str);
}

/// One tool invocation.
#[derive(Debug, Clone)]
pub struct ToolCommand {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub envs: Vec<(OsString, OsString)>,
    pub timeout: Duration,
}

impl ToolCommand {
    pub fn new(program: &Path) -> Self {
        Self {
            program: program.to_path_buf(),
            args: Vec::new(),
            envs: Vec::new(),
            timeout: DEFAULT_TIMEOUT,
        }
    }

    #[must_use]
    pub fn arg(mut self, arg: impl Into<OsString>) -> Self {
        self.args.push(arg.into());
        self
    }

    #[must_use]
    pub fn env(mut self, key: impl Into<OsString>, value: impl Into<OsString>) -> Self {
        self.envs.push((key.into(), value.into()));
        self
    }

    /// The program's file name.
    pub fn name(&self) -> String {
        self.program
            .file_name()
            .unwrap_or(self.program.as_os_str())
            .to_string_lossy()
            .into_owned()
    }

    /// `name arg arg…` for the log; arguments with spaces are quoted.
    pub fn display(&self) -> String {
        let mut text = self.name();
        for arg in &self.args {
            let arg = arg.to_string_lossy();
            text.push(' ');
            if arg.contains(' ') {
                text.push('"');
                text.push_str(&arg);
                text.push('"');
            } else {
                text.push_str(&arg);
            }
        }
        text
    }
}

/// A tool run that exited with status 0.
#[derive(Debug)]
pub struct ToolOutput {
    pub stdout: Vec<String>,
    pub elapsed: Duration,
}

#[derive(Debug, Error)]
pub enum RunError {
    #[error("Cannot start {program}: {source}")]
    Spawn {
        program: String,
        #[source]
        source: io::Error,
    },
    /// Non-zero exit; `message` is the tool's stderr text (or the exit status when stderr is empty).
    #[error("{message}")]
    Failed {
        program: String,
        code: Option<i32>,
        message: String,
    },
    #[error("{program} did not finish within {} s and was stopped.", .timeout.as_secs())]
    TimedOut { program: String, timeout: Duration },
    #[error("{program} was cancelled.")]
    Cancelled { program: String },
    #[error("Waiting for {program} failed: {source}")]
    Wait {
        program: String,
        #[source]
        source: io::Error,
    },
}

enum Outcome {
    Exited(io::Result<std::process::ExitStatus>),
    TimedOut,
    Cancelled,
}

/// Runs `cmd` to completion, streaming its output into `sink`.
///
/// Stops the whole process group when `cmd.timeout` passes or `cancel` turns `true`
/// (SIGTERM, then SIGKILL after a grace period) and always reaps the child before returning.
/// If the returned future is dropped mid-run, the group is killed.
pub async fn run(
    cmd: &ToolCommand,
    sink: &dyn LogSink,
    cancel: &mut watch::Receiver<bool>,
) -> Result<ToolOutput, RunError> {
    let started = Instant::now();
    let program = cmd.name();
    if *cancel.borrow_and_update() {
        return Err(RunError::Cancelled { program });
    }

    let mut command = Command::new(&cmd.program);
    command
        .args(&cmd.args)
        .envs(cmd.envs.iter().map(|(k, v)| (k, v)))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    #[cfg(unix)]
    command.process_group(0);

    let mut child = command.spawn().map_err(|source| RunError::Spawn {
        program: program.clone(),
        source,
    })?;
    let mut group = GroupGuard::new(child.id());
    let stdout = child.stdout.take().expect("stdout is piped");
    let stderr = child.stderr.take().expect("stderr is piped");

    let mut out_lines = Vec::new();
    let mut err_tail = VecDeque::with_capacity(STDERR_TAIL);
    let outcome = {
        let work = async {
            tokio::join!(
                pump(stdout, LogStream::Stdout, sink, |line| out_lines.push(line)),
                pump(stderr, LogStream::Stderr, sink, |line| {
                    if err_tail.len() == STDERR_TAIL {
                        err_tail.pop_front();
                    }
                    err_tail.push_back(line);
                }),
            );
            child.wait().await
        };
        tokio::select! {
            status = work => Outcome::Exited(status),
            () = tokio::time::sleep(cmd.timeout) => Outcome::TimedOut,
            () = cancelled(cancel) => Outcome::Cancelled,
        }
    };

    match outcome {
        Outcome::Exited(status) => {
            let status = status.map_err(|source| RunError::Wait {
                program: program.clone(),
                source,
            })?;
            group.disarm();
            if status.success() {
                Ok(ToolOutput {
                    stdout: out_lines,
                    elapsed: started.elapsed(),
                })
            } else {
                let message = failure_message(&program, &err_tail, status);
                Err(RunError::Failed {
                    program,
                    code: status.code(),
                    message,
                })
            }
        }
        Outcome::TimedOut => {
            terminate(&mut child, &mut group).await;
            Err(RunError::TimedOut {
                program,
                timeout: cmd.timeout,
            })
        }
        Outcome::Cancelled => {
            terminate(&mut child, &mut group).await;
            Err(RunError::Cancelled { program })
        }
    }
}

async fn pump<R: AsyncRead + Unpin>(
    pipe: R,
    stream: LogStream,
    sink: &dyn LogSink,
    mut keep: impl FnMut(String),
) {
    let mut reader = BufReader::new(pipe);
    let mut buffer = Vec::new();
    loop {
        buffer.clear();
        match reader.read_until(b'\n', &mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                while matches!(buffer.last(), Some(b'\n' | b'\r')) {
                    buffer.pop();
                }
                let line = String::from_utf8_lossy(&buffer).into_owned();
                sink.line(stream, &line);
                keep(line);
            }
        }
    }
}

async fn cancelled(cancel: &mut watch::Receiver<bool>) {
    loop {
        if *cancel.borrow_and_update() {
            return;
        }
        if cancel.changed().await.is_err() {
            // The sender is gone: nobody can cancel any more.
            std::future::pending::<()>().await;
        }
    }
}

/// SIGTERM to the group, wait up to the grace period, SIGKILL whatever is left, reap.
async fn terminate(child: &mut Child, group: &mut GroupGuard) {
    group.terminate();
    let exited = tokio::time::timeout(TERM_GRACE, child.wait()).await.is_ok();
    group.kill();
    if !exited {
        let _ = child.start_kill();
        let _ = child.wait().await;
    }
    group.disarm();
}

fn failure_message(
    program: &str,
    err_tail: &VecDeque<String>,
    status: std::process::ExitStatus,
) -> String {
    let text = err_tail
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned();
    if !text.is_empty() {
        return text;
    }
    match status.code() {
        Some(code) => format!("{program} exited with code {code}."),
        None => format!("{program} was terminated by a signal."),
    }
}

/// Signals the child's process group; kills it on drop unless disarmed after reaping.
struct GroupGuard {
    pgid: Option<i32>,
}

impl GroupGuard {
    fn new(pid: Option<u32>) -> Self {
        Self {
            pgid: pid.and_then(|pid| i32::try_from(pid).ok()),
        }
    }

    fn terminate(&self) {
        #[cfg(unix)]
        self.signal(libc::SIGTERM);
    }

    fn kill(&self) {
        #[cfg(unix)]
        self.signal(libc::SIGKILL);
    }

    #[cfg(unix)]
    fn signal(&self, signal: i32) {
        if let Some(pgid) = self.pgid {
            // SAFETY: killpg only sends a signal. `pgid` is the group `process_group(0)` created
            // for our child; the guard is disarmed right after the child is reaped, so the id is
            // still ours (a group id is not reused while any member is alive).
            unsafe {
                libc::killpg(pgid, signal);
            }
        }
    }

    fn disarm(&mut self) {
        self.pgid = None;
    }
}

impl Drop for GroupGuard {
    fn drop(&mut self) {
        self.kill();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct Collect(Mutex<Vec<(LogStream, String)>>);

    impl LogSink for Collect {
        fn line(&self, stream: LogStream, text: &str) {
            self.0.lock().expect("lock").push((stream, text.to_owned()));
        }
    }

    fn sh(script: &str) -> ToolCommand {
        ToolCommand::new(Path::new("/bin/sh")).arg("-c").arg(script)
    }

    fn alive(pid: i32) -> bool {
        // SAFETY: signal 0 only checks that the process exists.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    #[tokio::test]
    async fn streams_both_pipes_and_keeps_stdout() {
        let sink = Collect::default();
        let (_tx, mut rx) = watch::channel(false);
        let out = run(
            &sh("echo one; echo two >&2; printf 'three\\r\\n'"),
            &sink,
            &mut rx,
        )
        .await
        .expect("runs");
        assert_eq!(out.stdout, vec!["one", "three"]);
        let lines = sink.0.lock().expect("lock").clone();
        assert!(lines.contains(&(LogStream::Stderr, "two".to_owned())));
    }

    #[tokio::test]
    async fn failure_carries_stderr_text() {
        let sink = Collect::default();
        let (_tx, mut rx) = watch::channel(false);
        let err = run(
            &sh("echo 'error: txt line 3, column 2: bad' >&2; exit 1"),
            &sink,
            &mut rx,
        )
        .await
        .expect_err("fails");
        assert!(matches!(&err, RunError::Failed { code: Some(1), .. }));
        assert_eq!(err.to_string(), "error: txt line 3, column 2: bad");
    }

    #[tokio::test]
    async fn timeout_kills_the_whole_group() {
        let sink = Collect::default();
        let (_tx, mut rx) = watch::channel(false);
        let mut cmd = sh("sleep 30 & echo $!; wait");
        cmd.timeout = Duration::from_millis(300);
        let started = Instant::now();
        let err = run(&cmd, &sink, &mut rx).await.expect_err("times out");
        assert!(matches!(err, RunError::TimedOut { .. }));
        assert!(started.elapsed() < Duration::from_secs(5));
        let first_line = sink.0.lock().expect("lock")[0].1.clone();
        let grandchild: i32 = first_line.parse().expect("pid line");
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!alive(grandchild), "background sleep survived");
    }

    #[tokio::test]
    async fn cancel_stops_the_tool() {
        let sink = Collect::default();
        let (tx, mut rx) = watch::channel(false);
        let cancel = async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            tx.send_replace(true);
            tx
        };
        let cmd = sh("sleep 30");
        let (result, _tx) = tokio::join!(run(&cmd, &sink, &mut rx), cancel);
        assert!(matches!(result, Err(RunError::Cancelled { .. })));
    }

    #[tokio::test]
    async fn missing_program_is_a_spawn_error() {
        let sink = Collect::default();
        let (_tx, mut rx) = watch::channel(false);
        let err = run(
            &ToolCommand::new(Path::new("/nonexistent/l2dat")),
            &sink,
            &mut rx,
        )
        .await
        .expect_err("fails");
        assert!(matches!(err, RunError::Spawn { .. }));
    }
}
