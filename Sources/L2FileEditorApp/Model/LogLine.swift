/// One line of the Program Log pane.
struct LogLine: Identifiable, Sendable, Equatable {
    enum Level: Sendable, Equatable {
        case info
        case warning
        case error
    }

    let id: Int
    let text: String
    let level: Level
}
