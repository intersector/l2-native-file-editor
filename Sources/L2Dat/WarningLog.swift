/// Collects warnings with a hard cap so a pathological file cannot produce millions of strings.
struct WarningLog {
    static let limit = 1000
    private(set) var items: [L2DatWarning] = []
    private var suppressed = 0

    mutating func add(_ warning: L2DatWarning) {
        if items.count < Self.limit { items.append(warning) } else { suppressed += 1 }
    }

    var finished: [L2DatWarning] {
        guard suppressed > 0 else { return items }
        return items + [L2DatWarning(message: "\(suppressed) more warnings suppressed")]
    }
}
