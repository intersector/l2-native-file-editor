import ArgumentParser
import L2Crypt
import L2Dat

/// `l2dat save`: asm + encode in one step, as the GUI's Save & Encrypt does.
struct SaveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Assemble text and encrypt the result into a client .dat (asm + encode).",
        discussion: "The DDF must carry SOFT limits: use the -e export of open or disasm."
    )

    @Argument(help: "Input .txt.")
    var input: String

    @Option(name: .customShort("d"), help: ArgumentHelp("DDF with SOFT limits (open/disasm -e output).", valueName: "ddf"))
    var ddf: String

    @Option(name: .customShort("p"), help: ArgumentHelp("Protocol to encrypt with (e.g. 413).", valueName: "proto"))
    var proto: ProtocolArgument

    @Option(name: .customShort("o"), help: ArgumentHelp("Output encrypted .dat.", valueName: "out"))
    var output: String

    @Option(name: .customShort("f"),
        help: ArgumentHelp("File name the protocol-121 key derives from (default: the output's name).", valueName: "origname"))
    var originalName: String?

    func run() async throws {
        try await Console.reportingErrors {
            let ddfURL = FileIO.url(ddf)
            let schema = try SchemaFile.load(ddfURL)
            let input = FileIO.url(self.input)
            let output = FileIO.url(self.output)
            try FileIO.requireDistinct(input: input, output: output)
            try FileIO.requireNotSchema(output, schema: ddfURL)
            try FileIO.requireOutputDirectory(output)
            let codec = try L2Crypt()

            let result = try Assembler.assemble(txt: try FileIO.read(input), schema: schema)
            Console.warn(result.warnings)
            let scratch = try TemporaryDirectory()
            defer { scratch.remove() }
            let plain = scratch.file(output.lastPathComponent)
            try await FileIO.write(result.dat, to: plain)
            try await CryptStep.encode(
                codec, input: plain, output: output, protocol: proto.value,
                originalFileName: originalName ?? output.lastPathComponent)
            print("saved \(result.rowCount) rows (\(proto.value.header)) -> \(output.path)")
        }
    }
}
