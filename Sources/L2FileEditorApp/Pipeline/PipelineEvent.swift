import L2Dat

/// Progress reported by the open/save pipelines while they run.
enum PipelineEvent: Sendable {
    /// The step now running (shown next to the progress indicator).
    case step(String)
    /// A finished step or a note, for the Program Log.
    case log(String, LogLine.Level)

    /// Log events for L2Dat warnings, at most `limit` of them plus a summary line.
    static func warnings(_ warnings: [L2DatWarning], limit: Int = 20) -> [PipelineEvent] {
        var events = warnings.prefix(limit).map { PipelineEvent.log("|    warning: \($0)", .warning) }
        if warnings.count > limit {
            events.append(.log("|    … and \(warnings.count - limit) more warnings", .warning))
        }
        return events
    }
}

/// Receives pipeline events on the main actor, in order.
typealias PipelineReporter = @MainActor @Sendable (PipelineEvent) -> Void
