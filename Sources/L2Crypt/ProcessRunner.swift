#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Dispatch
import Foundation

/// Runs a child process to completion and captures its output.
///
/// The child is started with `posix_spawn` as the leader of its own process group, so stopping it
/// (`killpg`) also stops anything it started, such as the `sleep` of a shell script or a wine wrapper's
/// children. One thread drains both pipes with `poll` (a child that writes more than a pipe buffer never
/// blocks) and another waits for the leader. The run ends when the leader has exited and both pipes are
/// at EOF; once the leader has exited, the rest of its group is killed and only output already in the pipes
/// is read, so a leftover process holding a pipe never delays the result.
///
/// Cancelling the calling task or reaching `timeout` kills the whole group, closes the read ends (EOF is
/// never waited for, so even a process outside the group that holds a pipe cannot block the run), reaps the
/// leader and throws `L2CryptError.cancelled` / `.timedOut`. A task cancelled before the spawn never starts
/// the child.
struct ProcessRunner: Sendable {
    struct Output: Sendable {
        /// The exit code, or 128 + the signal number when the child was killed by a signal.
        var exitCode: Int32
        var stdout: [UInt8]
        var stderr: [UInt8]
    }

    let executable: URL
    /// Time limit of one run; nil for none.
    var timeout: Duration?

    func run(_ arguments: [String]) async throws -> Output {
        let path = executable.path
        guard !Task.isCancelled else { throw L2CryptError.cancelled(executable: path) }
        let child = try SpawnedChild.spawn(path, arguments: arguments)
        if let timeout { child.stop(after: timeout) }
        // A cancel that lands between the check above and this point runs `onCancel` on entry.
        let outcome = await withTaskCancellationHandler {
            await child.outcome()
        } onCancel: {
            child.stop(.cancelled)
        }
        switch outcome {
        case let .finished(output):
            return output
        case .stopped(.cancelled):
            throw L2CryptError.cancelled(executable: path)
        case .stopped(.timedOut):
            throw L2CryptError.timedOut(executable: path, timeout: timeout ?? .zero)
        }
    }
}

/// One spawned child: its process group, the pipe reader and the leader waiter.
///
/// Every mutable field is guarded by `lock`. The pipe read ends and the wake pipe's read end belong to the
/// reader thread, which closes them; the wake pipe's write end is only written under `lock` while the reader
/// is running and closed on `deinit`.
private final class SpawnedChild: @unchecked Sendable {
    enum StopReason: Sendable {
        case cancelled
        case timedOut
    }

    enum Outcome: Sendable {
        case finished(ProcessRunner.Output)
        case stopped(StopReason)
    }

    /// What the reader does next, read when the wake pipe becomes readable.
    private enum ReaderMode {
        /// Read until both pipes are at EOF.
        case running
        /// The leader has exited: read what is already in the pipes, then stop.
        case draining
        /// The group was killed: stop now.
        case aborted
    }

    /// After a stop, how long to wait for the killed leader to be reaped before reporting the stop anyway.
    private static let reapGrace: DispatchTimeInterval = .seconds(1)

    private let pid: pid_t
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()

    private var mode = ReaderMode.running
    private var readerDone = false
    private var stdout: [UInt8] = []
    private var stderr: [UInt8] = []
    /// The leader has exited (it may not be reaped yet); its group id may be reused after it is reaped,
    /// so the group is only signalled before this is set.
    private var leaderExited = false
    private var exitCode: Int32?
    private var stopReason: StopReason?
    private var graceExpired = false
    private var timer: DispatchWorkItem?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var delivered = false

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32, wakeRead: Int32, wakeWrite: Int32) {
        self.pid = pid
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.wakeRead = wakeRead
        self.wakeWrite = wakeWrite
    }

    deinit {
        close(wakeWrite)
    }

    // MARK: - Spawn

    /// Starts `path` with `arguments` in a new process group (stdin `/dev/null`, stdout and stderr piped)
    /// and starts the reader and waiter threads.
    static func spawn(_ path: String, arguments: [String]) throws -> SpawnedChild {
        func failure(_ step: String, _ code: Int32) -> L2CryptError {
            .launchFailed(executable: path, reason: "\(step): \(String(cString: strerror(code)))")
        }
        var opened: [Int32] = []
        defer { for fd in opened { close(fd) } }
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw failure("pipe", errno) }
            opened += fds
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }
        let out = try makePipe()
        let err = try makePipe()
        let wake = try makePipe()
        _ = fcntl(wake.write, F_SETFL, fcntl(wake.write, F_GETFL) | O_NONBLOCK)

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out.write, 1)
        posix_spawn_file_actions_adddup2(&actions, err.write, 2)
        var flags = Int32(POSIX_SPAWN_SETPGROUP) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        // Only the descriptors set up above reach the child, even ones another thread opens meanwhile.
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        // Linux has no POSIX_SPAWN_CLOEXEC_DEFAULT: close every descriptor above stderr in the child
        // (glibc >= 2.34), after the dup2s above.
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        // Process group id 0: the child leads a new group whose id is its pid.
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in envp { free(pointer) } }

        var pid = pid_t()
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw failure("posix_spawn", result) }
        LiveProcessGroups.insert(pid)

        // The parent keeps only the read ends and the wake pipe; the write ends now live in the child alone.
        close(out.write)
        close(err.write)
        opened = []
        let child = SpawnedChild(
            pid: pid, stdoutFD: out.read, stderrFD: err.read, wakeRead: wake.read, wakeWrite: wake.write)
        Thread.detachNewThread { child.readPipes() }
        Thread.detachNewThread { child.waitForLeader() }
        return child
    }

    // MARK: - Control

    /// The result, once the run ended or was stopped.
    func outcome() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let ready = takeOutcome()
            lock.unlock()
            resume(ready)
        }
    }

    func stop(after timeout: Duration) {
        let item = DispatchWorkItem { [weak self] in self?.stop(.timedOut) }
        lock.lock()
        timer = item
        lock.unlock()
        let (seconds, attoseconds) = timeout.components
        DispatchQueue.global().asyncAfter(
            deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18, execute: item)
    }

    /// Kills the process group and stops reading; does nothing once the run has ended.
    func stop(_ reason: StopReason) {
        lock.lock()
        guard stopReason == nil, !delivered, !(readerDone && exitCode != nil) else {
            lock.unlock()
            return
        }
        stopReason = reason
        if !leaderExited { killpg(pid, SIGKILL) }
        setReaderMode(.aborted)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.reapGrace) { [self] in
            lock.lock()
            graceExpired = true
            let ready = takeOutcome()
            lock.unlock()
            resume(ready)
        }
    }

    /// Call with `lock` held.
    private func setReaderMode(_ newMode: ReaderMode) {
        guard !readerDone, mode != .aborted else { return }
        mode = newMode
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    /// The outcome, when it is ready and not yet delivered, with the continuation to deliver it to. Call with
    /// `lock` held; marks it delivered.
    private func takeOutcome() -> (CheckedContinuation<Outcome, Never>, Outcome)? {
        guard !delivered, let continuation, readerDone else { return nil }
        let outcome: Outcome
        if let stopReason {
            guard exitCode != nil || graceExpired else { return nil }
            outcome = .stopped(stopReason)
        } else {
            guard let exitCode else { return nil }
            outcome = .finished(ProcessRunner.Output(exitCode: exitCode, stdout: stdout, stderr: stderr))
        }
        delivered = true
        self.continuation = nil
        timer?.cancel()
        timer = nil
        return (continuation, outcome)
    }

    private func resume(_ ready: (CheckedContinuation<Outcome, Never>, Outcome)?) {
        if let (continuation, outcome) = ready { continuation.resume(returning: outcome) }
    }

    // MARK: - Threads

    /// Reads both pipes until EOF, until the leader has exited and the pipes hold no more data, or until the
    /// group is killed; then closes the read ends.
    private func readPipes() {
        var collected: [[UInt8]] = [[], []]
        var isOpen = [true, true]
        let fds = [stdoutFD, stderrFD]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var draining = false
        let events = Int16(POLLIN)

        reading: while isOpen[0] || isOpen[1] {
            var polled = [
                pollfd(fd: isOpen[0] ? fds[0] : -1, events: events, revents: 0),
                pollfd(fd: isOpen[1] ? fds[1] : -1, events: events, revents: 0),
                pollfd(fd: wakeRead, events: events, revents: 0),
            ]
            let ready = poll(&polled, nfds_t(polled.count), draining ? 0 : -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }
            if polled[2].revents != 0 {
                var discard = [UInt8](repeating: 0, count: 16)
                _ = read(wakeRead, &discard, discard.count)
                lock.lock()
                let current = mode
                lock.unlock()
                switch current {
                case .running: break
                case .draining: draining = true
                case .aborted: break reading
                }
            }
            for index in 0..<2 where isOpen[index] && polled[index].revents != 0 {
                let count = buffer.withUnsafeMutableBytes { read(fds[index], $0.baseAddress, $0.count) }
                if count > 0 {
                    collected[index].append(contentsOf: buffer[0..<count])
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    isOpen[index] = false
                }
            }
        }

        lock.lock()
        readerDone = true
        stdout = collected[0]
        stderr = collected[1]
        let ready = takeOutcome()
        lock.unlock()
        // Closing the read ends makes any writer that is left (one outside the group) fail with EPIPE.
        close(stdoutFD)
        close(stderrFD)
        close(wakeRead)
        resume(ready)
    }

    /// Waits for the leader to exit, kills what is left of its group, reaps it and records the exit code.
    private func waitForLeader() {
        var info = siginfo_t()
        // WNOWAIT: the exited leader stays a zombie, so its pid (the group id) cannot be reused yet.
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        lock.lock()
        killpg(pid, SIGKILL)
        leaderExited = true
        lock.unlock()
        // Before the reap: once reaped, the group id may name another process's group.
        LiveProcessGroups.remove(pid)

        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
        let signal = status & 0x7F
        let code: Int32 = reaped < 0 ? -1 : (signal == 0 ? (status >> 8) & 0xFF : 128 + signal)

        lock.lock()
        exitCode = code
        setReaderMode(.draining)
        let ready = takeOutcome()
        lock.unlock()
        resume(ready)
    }
}

/// The process groups of the helper runs in progress in this process, for `L2Crypt.stopRunningHelpers()`,
/// which a signal handler calls.
///
/// A fixed table of `pid_t` slots (0 = free), allocated once and never freed, so reading it allocates
/// nothing. Writers hold `lock`; the signal handler reads without it. That relies on a load or store of an
/// aligned 32-bit word being one untorn access, which holds on arm64 and x86_64: a reader sees a slot's old
/// or new value. A slot is filled right after `posix_spawn` returns (a signal in between misses that child)
/// and cleared after the leader exited but before it is reaped, so a group id read from the table names a
/// running helper's group or the group of its zombie leader, never a reused pid. A full table only means
/// that run is not stopped by a signal handler.
enum LiveProcessGroups {
    private static let capacity = 64

    nonisolated(unsafe) private static let slots: UnsafeMutablePointer<pid_t> = {
        let table = UnsafeMutablePointer<pid_t>.allocate(capacity: capacity)
        table.initialize(repeating: 0, count: capacity)
        return table
    }()

    private static let lock = NSLock()

    /// Allocates the table, so a signal handler never initialises it.
    static func prepare() {
        _ = slots
    }

    static func insert(_ group: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        for index in 0..<capacity where slots[index] == 0 {
            slots[index] = group
            return
        }
    }

    static func remove(_ group: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        for index in 0..<capacity where slots[index] == group {
            slots[index] = 0
        }
    }

    /// Kills every group in the table with SIGKILL and waits until its leader has exited, without reaping
    /// it (`WNOWAIT`), so no helper is still inside a system call (such as creating its `-o` file) when
    /// this returns. Only reads the table and calls `killpg(2)` and `waitid(2)`: async-signal-safe after
    /// `prepare()`. A leader that the waiter thread reaps meanwhile ends the wait with ECHILD.
    static func killAll() {
        for index in 0..<capacity {
            let group = slots[index]
            guard group > 0, killpg(group, SIGKILL) == 0 else { continue }
            var info = siginfo_t()
            while waitid(P_PID, id_t(group), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        }
    }
}
