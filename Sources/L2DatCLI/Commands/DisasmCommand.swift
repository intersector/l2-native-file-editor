import ArgumentParser
import L2Dat

/// `l2dat disasm`: l2disasm's flag contract over `Disassembler.run`.
struct DisasmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disasm",
        abstract: "Disassemble a decrypted .dat into tab-separated text (l2disasm).",
        discussion: """
            Same flags as l2disasm: l2dat disasm -d X.ddf -e X-new.ddf dec-X.dat X.txt
            Pass the -e export to asm: it carries the SOFT limits the assembler needs.
            Deviations from l2disasm: -l (legacy transliteration) is accepted but unsupported and \
            exits with status 1; the sign of a negative CNTR is dropped on read, as the original does.
            """
    )

    @Option(name: .customShort("d"), help: ArgumentHelp("DDF describing the .dat layout.", valueName: "ddf"))
    var ddf: String

    @Option(name: .customShort("e"),
        help: ArgumentHelp("Also write the DDF with the observed SOFT limits (the -new.ddf for asm).", valueName: "export.ddf"))
    var export: String?

    @Option(name: .customShort("o"), help: ArgumentHelp("Floats as f (%.8f) or e (%.8e).", valueName: "f|e"))
    var floatFormat: FloatFormatArgument = .f

    @Flag(name: .customShort("q"), help: "Do not print the header line.")
    var noHeader = false

    @Flag(name: .customShort("f"), help: "Print every ASCF with the a, hint.")
    var forceAsciiHint = false

    @Option(name: .customShort("a"), help: ArgumentHelp("8-bit ASCF charset: ISO-8859-1 or UTF-8.", valueName: "charset"))
    var charset: CharsetArgument = .isoLatin1

    @Flag(name: .customShort("l"), help: "Legacy transliteration (unsupported).")
    var legacy = false

    @Argument(help: "Decrypted input .dat.")
    var input: String

    @Argument(help: "Output .txt.")
    var output: String

    func run() async throws {
        try await Console.reportingErrors {
            guard !legacy else { throw CLIError.legacyTransliteration }
            let ddfURL = FileIO.url(ddf)
            let schema = try SchemaFile.load(ddfURL)
            let input = FileIO.url(self.input)
            let output = FileIO.url(self.output)
            try FileIO.requireDistinct(input: input, output: output)
            try FileIO.requireNotSchema(output, schema: ddfURL)
            try FileIO.requireOutputDirectory(output)
            let exportURL = export.map(FileIO.url)
            if let exportURL { try FileIO.requireExport(exportURL, input: input, output: output, schema: ddfURL) }
            let options = DisasmOptions(
                floatFormat: floatFormat.floatFormat, forceAsciiHint: forceAsciiHint, noHeader: noHeader,
                charset: charset.charset)
            let result = try Disassembler.run(dat: try FileIO.read(input), schema: schema, options: options)
            Console.warn(result.warnings)
            try await OutputStage.run { stage in
                try stage.add(result.txt, for: output)
                if let exportURL {
                    try stage.add(DDF.export(result.schema), for: exportURL)
                }
            }
        }
    }
}
