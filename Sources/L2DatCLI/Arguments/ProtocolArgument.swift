import ArgumentParser
import L2Crypt

/// `-p <proto>`: one of the protocol numbers l2encdec supports (111 ... 414).
struct ProtocolArgument: ExpressibleByArgument, Sendable {
    let value: L2Protocol

    init?(argument: String) {
        guard let number = Int(argument), let value = L2Protocol(rawValue: number) else { return nil }
        self.value = value
    }

    static var allValueStrings: [String] {
        L2Protocol.allCases.map { String($0.rawValue) }
    }
}
