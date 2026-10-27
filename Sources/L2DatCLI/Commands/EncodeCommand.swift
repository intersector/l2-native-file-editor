import ArgumentParser
import L2Crypt

/// `l2dat encode`: encrypt a decrypted client file with the l2encdec helper.
struct EncodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode",
        abstract: "Encrypt a decrypted Lineage II client file (l2encdec -c encode).",
        discussion: "Without -o the output is enc-<name> next to the input, like the original l2encdec."
    )

    @Argument(help: "Decrypted input file.")
    var input: String

    @Option(name: .customShort("p"), help: ArgumentHelp("Protocol to encrypt with (e.g. 413).", valueName: "proto"))
    var proto: ProtocolArgument

    @Option(name: .customShort("o"), help: ArgumentHelp("Output file (default: enc-<name>).", valueName: "out"))
    var output: String?

    @Option(name: .customShort("f"),
        help: ArgumentHelp("Original file name the protocol-121 key derives from, for renamed files.", valueName: "origname"))
    var originalName: String?

    func run() async throws {
        try await Console.reportingErrors {
            let input = FileIO.url(self.input)
            let output = self.output.map(FileIO.url) ?? FileIO.prefixed(input, with: "enc-")
            try await CryptStep.encode(
                try L2Crypt(), input: input, output: output, protocol: proto.value, originalFileName: originalName)
            print("encoded \(input.path) (\(proto.value.header)) -> \(output.path)")
        }
    }
}
