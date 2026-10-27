import ArgumentParser
import L2Dat

/// `l2dat asm`: l2asm's flag contract over `Assembler.assemble`.
struct AsmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "asm",
        abstract: "Assemble tab-separated text into a decrypted .dat (l2asm).",
        discussion: """
            Same flags as l2asm: l2dat asm -d X-new.ddf X.txt out.dat
            The DDF must carry SOFT limits for dynamic tables and compounds: use the -new.ddf \
            written by disasm -e.
            Deviations from l2asm: -l (legacy transliteration) is accepted but unsupported and exits \
            with status 1; cells are split on the DDF's FS (l2asm always splits on tab).
            """
    )

    @Option(name: .customShort("d"), help: ArgumentHelp("DDF with SOFT limits (disasm -e output).", valueName: "ddf"))
    var ddf: String

    @Flag(name: .customShort("q"), help: "The txt has no header line.")
    var noHeader = false

    @Flag(name: .customShort("f"), help: "Encode every ASCF as 8-bit.")
    var forceEightBit = false

    @Option(name: .customShort("a"), help: ArgumentHelp("8-bit ASCF charset: ISO-8859-1 or UTF-8.", valueName: "charset"))
    var charset: CharsetArgument = .isoLatin1

    @Flag(name: .customShort("l"), help: "Legacy transliteration (unsupported).")
    var legacy = false

    @Argument(help: "Input .txt.")
    var input: String

    @Argument(help: "Output decrypted .dat.")
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
            let options = AsmOptions(forceEightBit: forceEightBit, noHeader: noHeader, charset: charset.charset)
            let result = try Assembler.assemble(txt: try FileIO.read(input), schema: schema, options: options)
            Console.warn(result.warnings)
            try await FileIO.write(result.dat, to: output)
        }
    }
}
