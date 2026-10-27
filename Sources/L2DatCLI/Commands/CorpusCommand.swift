import ArgumentParser
import L2Crypt

/// `l2dat corpus`: the golden-corpus integration test over `<fixtures>/RESULTS.tsv`.
struct CorpusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpus",
        abstract: "Check every RESULTS.tsv row of a golden corpus (decode, disasm, asm, DDF export).",
        discussion: """
            For each row: decode(enc/<name>.dat) vs dec/dec-<name>.dat; disasm(dec, <ddf>/<name>.ddf) \
            vs txt/<name>.txt; asm(txt, ddf/<name>-new.ddf) vs dec; exported DDF vs ddf/<name>-new.ddf.
            Rows the original tools did not round-trip (expected DIFF/FAIL) are reported as KNOWN. \
            Exits with status 1 when any IDENTICAL row fails a check.
            """
    )

    @Option(help: "Corpus directory with RESULTS.tsv and enc/, dec/, txt/, ddf/.")
    var fixtures: String

    @Option(help: "Directory of the DDFs the corpus was disassembled with (DAT_defs/CT2_6).")
    var ddf: String

    func run() async throws {
        try await Console.reportingErrors {
            let fixtures = FileIO.url(self.fixtures)
            let ddfDirectory = FileIO.url(ddf)
            try FileIO.requireDirectory(fixtures)
            try FileIO.requireDirectory(ddfDirectory)
            let entries = try CorpusEntry.load(fixtures.appendingPathComponent("RESULTS.tsv"))
            let codec = try L2Crypt()
            let scratch = try TemporaryDirectory()
            defer { scratch.remove() }

            let checker = CorpusChecker(fixtures: fixtures, ddfDirectory: ddfDirectory, codec: codec, scratch: scratch)
            let outcomes = await checker.run(entries)
            report(outcomes)
            let failed = outcomes.filter { $0.status == "FAIL" }
            if !failed.isEmpty {
                let expectedIdentical = outcomes.filter(\.entry.expectsIdentical).count
                Console.error(
                    "\(failed.count) of \(expectedIdentical) IDENTICAL corpus rows failed: "
                        + failed.map(\.entry.file).joined(separator: ", "))
                throw ExitCode.failure
            }
        }
    }

    private func report(_ outcomes: [CorpusOutcome]) {
        print(CorpusOutcome.header)
        for outcome in outcomes {
            print(outcome.row)
        }

        let notes = outcomes.flatMap { outcome in
            outcome.checks.compactMap { name, check in check.detail.map { "  \(outcome.entry.file) \(name): \($0)" } }
        }
        if !notes.isEmpty {
            print("\nnotes:")
            notes.forEach { print($0) }
        }

        let expectedIdentical = outcomes.filter(\.entry.expectsIdentical)
        let passed = expectedIdentical.filter { $0.status == "PASS" }
        let failed = expectedIdentical.filter { $0.status == "FAIL" }.map(\.entry.file)
        let known = outcomes.filter { !$0.entry.expectsIdentical }.map { "\($0.entry.file) (\($0.entry.expected))" }
        var summary = "\nsummary: \(passed.count)/\(expectedIdentical.count) IDENTICAL rows pass all four checks"
        if !failed.isEmpty { summary += "; FAILED: \(failed.joined(separator: ", "))" }
        if !known.isEmpty { summary += "; \(known.count) known non-identical rows reported: \(known.joined(separator: ", "))" }
        print(summary)
    }
}
