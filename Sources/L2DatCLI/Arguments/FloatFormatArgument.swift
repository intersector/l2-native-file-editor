import ArgumentParser
import L2Dat

/// `-o f|e` of l2disasm: fixed (`%.8f`) or scientific (`%.8e`) float output.
enum FloatFormatArgument: String, CaseIterable, ExpressibleByArgument, Sendable {
    case f
    case e

    var floatFormat: DisasmOptions.FloatFormat {
        switch self {
        case .f: return .fixed
        case .e: return .scientific
        }
    }
}
