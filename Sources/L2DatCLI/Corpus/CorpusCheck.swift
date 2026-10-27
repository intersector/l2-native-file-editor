/// Result of one comparison of the corpus run.
enum CorpusCheck: Sendable {
    case identical
    case different(ByteDiff, binary: Bool)
    case failed(String)
    case skipped(String)

    static func compare(_ actual: [UInt8], _ expected: [UInt8], binary: Bool) -> CorpusCheck {
        ByteDiff.between(actual, expected).map { .different($0, binary: binary) } ?? .identical
    }

    var isIdentical: Bool {
        if case .identical = self { return true }
        return false
    }

    var cell: String {
        switch self {
        case .identical: return "IDENTICAL"
        case .different: return "DIFF"
        case .failed: return "FAIL"
        case .skipped: return "-"
        }
    }

    /// Explanation for a non-identical result.
    var detail: String? {
        switch self {
        case .identical: return nil
        case let .different(diff, binary): return binary ? diff.binaryDescription : diff.textDescription
        case let .failed(message): return message
        case let .skipped(reason): return "skipped: \(reason)"
        }
    }
}
