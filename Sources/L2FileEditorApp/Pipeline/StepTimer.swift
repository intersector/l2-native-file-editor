import Foundation

/// Measures pipeline steps for the log's timings.
struct StepTimer: Sendable {
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var lapStarted: ContinuousClock.Instant

    init() {
        started = clock.now
        lapStarted = started
    }

    /// Time since the previous lap (or the start), then starts a new lap.
    mutating func lap() -> Duration {
        let now = clock.now
        defer { lapStarted = now }
        return now - lapStarted
    }

    /// Time since the timer was created.
    var total: Duration { clock.now - started }

    /// `0.123 s`.
    static func format(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.3f s", Double(seconds) + Double(attoseconds) / 1e18)
    }
}
