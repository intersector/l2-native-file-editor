import Foundation
import L2Crypt
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The temporary files and scratch directories this process created and has not renamed or
/// removed yet, cleaned up by a SIGINT/SIGTERM/SIGHUP handler before the signal is raised again
/// with its default action (exit status 128 + the signal number).
///
/// The handler first kills every running l2encdec helper with its process group and waits for
/// it to exit (`L2Crypt.stopRunningHelpers()`): the helper leads its own group, so a terminal's
/// signal never reaches it, and it would otherwise recreate its `-o` file after the unlink. Then
/// it unlinks the registered files and removes the registered directories (`rmdir(2)`, after
/// their files). It only reads fixed tables of C strings and calls `killpg(2)`, `waitid(2)`,
/// `unlink(2)`, `rmdir(2)`, `signal(2)` and `raise(3)`: no allocation, lock, Foundation or
/// printing. A removed entry's string is never freed, because the handler may be reading it on
/// another thread; a command creates a few dozen temporaries at most, so the leak is small.
/// A backup that is the only copy of an output's data (see `FileIO.backUp`) is not registered.
/// A SIGKILL cannot be handled, so it can leave a `.l2dat-*.tmp` or scratch directory behind.
/// Every command installs the handlers before it starts (`installHandlers()`), so no temporary file
/// exists before them. A file is registered right after `open(O_CREAT | O_EXCL)` or `linkat(2)`
/// created it, never before (on EEXIST the name is someone else's file). The handler may run on
/// another thread while a file is being created; if it scans the table before that file is
/// registered, that one file is left behind (known window, not closed yet: roughly 100 µs on the
/// creating thread, seen in about 1% of signals sent 2-8 ms after start).
///
/// The handler runs on one thread while the command goes on in others, and killing the helper
/// makes the command fail there. So the handler first sets `stopping`; from then on a thread that
/// would end the process normally (an error report, or `exit` through an `atexit` hook) waits for
/// the handler instead, and the process always ends by the signal.
enum TemporaryFiles {
    private static let capacity = 64

    /// The tables; a slot is nil or a `strdup`ed path. Written only under `lock`.
    nonisolated(unsafe) private static let files = makeTable()
    nonisolated(unsafe) private static let directories = makeTable()

    /// Nonzero once a handler started. An aligned 32-bit word: one untorn access on arm64 and
    /// x86_64, like `sig_atomic_t`.
    nonisolated(unsafe) private static let stopping: UnsafeMutablePointer<Int32> = {
        let word = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        word.initialize(to: 0)
        return word
    }()

    private static let lock = NSLock()

    private static func makeTable() -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let table = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: capacity)
        table.initialize(repeating: nil, count: capacity)
        return table
    }

    /// Installs the SIGINT/SIGTERM/SIGHUP handlers; only the first call does anything. Call it
    /// before creating any temporary file: a signal before it gets the default action.
    static func installHandlers() {
        _ = handlersInstalled
    }

    /// Whether SIGTERM currently runs the cleanup handler (asks the kernel with `sigaction(2)`).
    static var isHandlingSignals: Bool {
        var current = sigaction()
        guard sigaction(SIGTERM, nil, &current) == 0 else { return false }
        #if canImport(Darwin)
        let handler = unsafeBitCast(current.__sigaction_u, to: UInt.self)
        #else
        let handler = unsafeBitCast(current.__sigaction_handler, to: UInt.self)
        #endif
        return handler == unsafeBitCast(stopCleanAndReraise, to: UInt.self)
    }

    /// Installs the handlers once, after everything the handler reads exists, so the handler
    /// never initialises anything.
    private static let handlersInstalled: Bool = {
        _ = files
        _ = directories
        _ = stopping
        L2Crypt.prepareToStopHelpersFromSignalHandler()
        atexit {
            if TemporaryFiles.isStopping { TemporaryFiles.waitForSignalHandler() }
        }
        install(SIGINT)
        install(SIGTERM)
        install(SIGHUP)
        return true
    }()

    /// Catches `number` unless it is ignored (e.g. SIGINT of a background job), which stays so.
    private static func install(_ number: Int32) {
        let previous = signal(number, stopCleanAndReraise)
        // SIG_IGN is the handler value 1 on Darwin and Linux; the bit cast also covers the
        // optional handler type the two C libraries import.
        if unsafeBitCast(previous, to: UInt.self) == 1 {
            signal(number, SIG_IGN)
        }
    }

    /// Whether a signal handler is cleaning up; the process is about to end by that signal.
    static var isStopping: Bool {
        stopping.pointee != 0
    }

    /// Blocks the calling thread until the handler, running on another thread, ends the process.
    static func waitForSignalHandler() -> Never {
        while true { pause() }
    }

    static func register(_ url: URL) {
        insert(url.path, into: files)
    }

    static func unregister(_ url: URL) {
        let path = url.path
        remove(from: files) { strcmp($0, path) == 0 }
    }

    /// Registers a scratch directory; register it before creating it, so a signal in between
    /// cannot leave it behind.
    static func registerDirectory(_ url: URL) {
        insert(url.path, into: directories)
    }

    /// Unregisters a scratch directory and every file registered below it.
    static func unregisterDirectory(_ url: URL) {
        let path = url.path
        let prefix = path + "/"
        remove(from: directories) { strcmp($0, path) == 0 }
        remove(from: files) { String(cString: $0).hasPrefix(prefix) }
    }

    private static func insert(_ path: String, into table: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        installHandlers()
        lock.lock()
        defer { lock.unlock() }
        // A full table only means this entry is not removed on a signal.
        for index in 0..<capacity where table[index] == nil {
            table[index] = strdup(path)
            return
        }
    }

    private static func remove(
        from table: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        where matches: (UnsafeMutablePointer<CChar>) -> Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        for index in 0..<capacity {
            if let path = table[index], matches(path) {
                table[index] = nil
            }
        }
    }

    private static let stopCleanAndReraise: @convention(c) (Int32) -> Void = { received in
        TemporaryFiles.stopping.pointee = 1
        L2Crypt.stopRunningHelpers()
        for index in 0..<TemporaryFiles.capacity {
            if let path = TemporaryFiles.files[index] {
                unlink(path)
            }
        }
        for index in 0..<TemporaryFiles.capacity {
            if let path = TemporaryFiles.directories[index] {
                rmdir(path)
            }
        }
        signal(received, SIG_DFL)
        raise(received)
    }
}
