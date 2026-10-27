import ArgumentParser
import Foundation
import L2Dat

/// `l2dat roundtrip`: disasm then asm with the effective schema, compared with the input.
struct RoundtripCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "roundtrip",
        abstract: "Disassemble and reassemble a decrypted .dat and compare the result with the input.",
        discussion: """
            Prints IDENTICAL (exit 0) or DIFF with the first differing dat offset and, when the \
            rebuilt file disassembles, the first differing txt line and column (exit 1).
            """
    )

    @Option(name: .customShort("d"), help: ArgumentHelp("DDF describing the .dat layout.", valueName: "ddf"))
    var ddf: String

    @Option(help: "Directory to keep <name>.txt, <name>-new.ddf and <name>-roundtrip.dat in.")
    var keep: String?

    @Argument(help: "Decrypted input .dat.")
    var input: String

    func validate() throws {
        if keep?.isEmpty == true {
            throw ValidationError("--keep needs a directory; use --keep . for the current directory")
        }
    }

    func run() async throws {
        try await Console.reportingErrors {
            let ddfURL = FileIO.url(ddf)
            let schema = try SchemaFile.load(ddfURL)
            let input = FileIO.url(self.input)
            let kept = keep.map { directory in
                let stem = input.deletingPathExtension().lastPathComponent
                let directory = FileIO.url(directory)
                return (
                    directory: directory,
                    txt: directory.appendingPathComponent("\(stem).txt"),
                    ddf: directory.appendingPathComponent("\(stem)-new.ddf"),
                    dat: directory.appendingPathComponent("\(stem)-roundtrip.dat"))
            }
            if let kept {
                try FileIO.requireCreatableDirectory(kept.directory)
                for target in [kept.txt, kept.ddf, kept.dat] {
                    try FileIO.requireDistinct(input: input, output: target)
                    try FileIO.requireNotSchema(target, schema: ddfURL)
                }
            }
            let original = try FileIO.read(input)
            let disasm = try Disassembler.run(dat: original, schema: schema)
            Console.warn(disasm.warnings)
            let rebuilt = try Assembler.assemble(txt: disasm.txt, schema: disasm.schema)
            Console.warn(rebuilt.warnings)

            if let kept {
                try FileIO.createDirectory(kept.directory)
                for target in [kept.txt, kept.ddf, kept.dat] {
                    try FileIO.requireOutputDirectory(target)
                }
                try await OutputStage.run { stage in
                    try stage.add(disasm.txt, for: kept.txt)
                    try stage.add(DDF.export(disasm.schema), for: kept.ddf)
                    try stage.add(rebuilt.dat, for: kept.dat)
                }
            }

            guard let diff = ByteDiff.between(rebuilt.dat, original) else {
                print("IDENTICAL (\(disasm.recordCount) records, \(original.count) bytes)")
                return
            }
            print("DIFF: dat \(diff.binaryDescription); \(textDifference(rebuilt.dat, disasm))")
            Console.error("roundtrip of \(input.path) is not identical (dat \(diff.binaryDescription))")
            throw ExitCode.failure
        }
    }

    /// Where the rebuilt file's text first differs from the original's.
    private func textDifference(_ rebuilt: [UInt8], _ disasm: DisasmResult) -> String {
        do {
            let again = try Disassembler.run(dat: rebuilt, schema: disasm.schema)
            guard let diff = ByteDiff.between(again.txt, disasm.txt) else {
                return "both disassemble to the same txt"
            }
            return "txt line \(diff.line), column \(diff.column)"
        } catch {
            return "the rebuilt dat does not disassemble: \(Console.describe(error))"
        }
    }
}
