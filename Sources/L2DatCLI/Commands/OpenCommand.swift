import ArgumentParser
import L2Crypt
import L2Dat

/// `l2dat open`: decode + disasm in one step, as the GUI's Open & Decrypt does.
struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Decrypt and disassemble an encrypted .dat into text (decode + disasm).",
        discussion: "Write -e to keep the DDF with SOFT limits that save needs to rebuild the file."
    )

    @Argument(help: "Encrypted input .dat.")
    var input: String

    @Option(name: .customShort("d"), help: ArgumentHelp("DDF describing the .dat layout.", valueName: "ddf"))
    var ddf: String

    @Option(name: .customShort("p"),
        help: ArgumentHelp("Protocol; default: read from the file's Lineage2Ver### header.", valueName: "proto"))
    var proto: ProtocolArgument?

    @Option(name: .customShort("o"), help: ArgumentHelp("Output .txt.", valueName: "out"))
    var output: String

    @Option(name: .customShort("e"),
        help: ArgumentHelp("Also write the DDF with the observed SOFT limits (the -d of save).", valueName: "export.ddf"))
    var export: String?

    func run() async throws {
        try await Console.reportingErrors {
            let ddfURL = FileIO.url(ddf)
            let schema = try SchemaFile.load(ddfURL)
            let input = FileIO.url(self.input)
            let output = FileIO.url(self.output)
            try FileIO.requireDistinct(input: input, output: output)
            try FileIO.requireNotSchema(output, schema: ddfURL)
            try FileIO.requireOutputDirectory(output)
            let exportURL = export.map(FileIO.url)
            if let exportURL { try FileIO.requireExport(exportURL, input: input, output: output, schema: ddfURL) }

            let scratch = try TemporaryDirectory()
            defer { scratch.remove() }
            let decoded = scratch.file("dec-\(input.lastPathComponent)")
            let used = try await CryptStep.decode(try L2Crypt(), input: input, output: decoded, protocol: proto?.value)
            let result = try Disassembler.run(dat: try FileIO.read(decoded), schema: schema)
            Console.warn(result.warnings)
            try await OutputStage.run { stage in
                try stage.add(result.txt, for: output)
                if let exportURL {
                    try stage.add(DDF.export(result.schema), for: exportURL)
                }
            }
            print("opened \(input.path) (\(used.header)): \(result.recordCount) records -> \(output.path)")
        }
    }
}
