import Foundation
import L2Crypt
import L2Dat

/// Runs the four corpus checks of every row, several rows at a time.
struct CorpusChecker: Sendable {
    let fixtures: URL
    let ddfDirectory: URL
    let codec: L2Crypt
    let scratch: TemporaryDirectory

    /// Outcomes in the order of `entries`.
    func run(_ entries: [CorpusEntry]) async -> [CorpusOutcome] {
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var outcomes = [CorpusOutcome?](repeating: nil, count: entries.count)
        await withTaskGroup(of: (Int, CorpusOutcome).self) { group in
            var next = 0
            func addNext() {
                guard next < entries.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await check(entries[index])) }
            }
            for _ in 0..<width { addNext() }
            for await (index, outcome) in group {
                outcomes[index] = outcome
                addNext()
            }
        }
        return outcomes.compactMap { $0 }
    }

    func check(_ entry: CorpusEntry) async -> CorpusOutcome {
        let name = entry.file
        let golden: [UInt8]
        do {
            golden = try FileIO.read(fixtures.appendingPathComponent("dec/dec-\(name).dat"))
        } catch {
            let missing = CorpusCheck.failed(Console.describe(error))
            return CorpusOutcome(
                entry: entry, decode: missing, disasm: missing, asm: missing,
                export: .skipped("no decrypted fixture"), txtBytes: 0)
        }

        let decode = await checkDecode(name, golden: golden)
        let txtFile = fixtures.appendingPathComponent("txt/\(name).txt")
        let disasm: CorpusCheck
        let export: CorpusCheck
        var txtBytes = 0
        do {
            let schema = try SchemaFile.load(ddfDirectory.appendingPathComponent("\(name).ddf"))
            let result = try Disassembler.run(dat: golden, schema: schema)
            txtBytes = result.txt.count
            disasm = compare(result.txt, with: txtFile, binary: false)
            export = compare(DDF.export(result.schema), with: exportedDDF(name), binary: false)
        } catch {
            disasm = .failed(Console.describe(error))
            export = .skipped("disasm failed")
        }
        let asm: CorpusCheck
        do {
            let dat = try Assembler.run(txt: try FileIO.read(txtFile), schema: try SchemaFile.load(exportedDDF(name)))
            asm = CorpusCheck.compare(dat, golden, binary: true)
        } catch {
            asm = .failed(Console.describe(error))
        }
        return CorpusOutcome(entry: entry, decode: decode, disasm: disasm, asm: asm, export: export, txtBytes: txtBytes)
    }

    private func compare(_ actual: [UInt8], with file: URL, binary: Bool) -> CorpusCheck {
        do {
            return CorpusCheck.compare(actual, try FileIO.read(file), binary: binary)
        } catch {
            return .failed(Console.describe(error))
        }
    }

    private func checkDecode(_ name: String, golden: [UInt8]) async -> CorpusCheck {
        let output = scratch.file("dec-\(name).dat")
        defer { _ = FileIO.remove(output) }
        do {
            _ = try await CryptStep.decode(
                codec, input: fixtures.appendingPathComponent("enc/\(name).dat"), output: output, protocol: nil)
            return CorpusCheck.compare(try FileIO.read(output), golden, binary: true)
        } catch {
            return .failed(Console.describe(error))
        }
    }

    private func exportedDDF(_ name: String) -> URL {
        fixtures.appendingPathComponent("ddf/\(name)-new.ddf")
    }
}
