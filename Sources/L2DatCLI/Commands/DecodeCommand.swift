import ArgumentParser
import L2Crypt

/// `l2dat decode`: decrypt a client file with the l2encdec helper.
struct DecodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode",
        abstract: "Decrypt a Lineage II client file (l2encdec -c decode).",
        discussion: "Without -o the output is dec-<name> next to the input, like the original l2encdec."
    )

    @Argument(help: "Encrypted input file.")
    var input: String

    @Option(name: .customShort("o"), help: ArgumentHelp("Output file (default: dec-<name>).", valueName: "out"))
    var output: String?

    @Option(name: .customShort("p"),
        help: ArgumentHelp("Protocol; default: read from the file's Lineage2Ver### header.", valueName: "proto"))
    var proto: ProtocolArgument?

    @Flag(name: .customShort("l"), help: "Use the original NCSoft RSA keys (411-414).")
    var legacyKeys = false

    @Option(name: .customShort("f"),
        help: ArgumentHelp("Original file name the protocol-121 key derives from, for renamed files.", valueName: "origname"))
    var originalName: String?

    func run() async throws {
        try await Console.reportingErrors {
            let input = FileIO.url(self.input)
            let output = self.output.map(FileIO.url) ?? FileIO.prefixed(input, with: "dec-")
            let used = try await CryptStep.decode(
                try L2Crypt(), input: input, output: output, protocol: proto?.value,
                legacyKeys: legacyKeys, originalFileName: originalName)
            print("decoded \(input.path) (\(used.header)) -> \(output.path)")
        }
    }
}
