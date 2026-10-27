import ArgumentParser
import L2Dat

/// Root of the `l2dat` command line tool.
@main
struct L2DatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "l2dat",
        abstract: "Decode, encode, disassemble and assemble Lineage II client .dat files.",
        discussion: """
            Errors are printed on stderr and exit with status 1; usage errors exit with status 64. \
            Encryption runs the l2encdec helper: set L2ENCDEC to its path when it is not found \
            next to this executable.

            Outputs are first written to a hidden temporary file next to them, named \
            .l2dat-<16 hex digits>.tmp (mode 0600; it may hold decrypted data), and renamed into \
            place once every output of the command is complete; a replaced output keeps its file \
            mode. While the outputs are renamed, an existing output also has a second name of \
            that form (a hard link), so it is never missing; on a file system without hard links \
            it is moved to such a name instead. open, save and corpus keep intermediate files in \
            a private l2dat-<UUID> directory in the temporary directory. On SIGINT, SIGTERM or \
            SIGHUP, l2dat kills the running l2encdec helper (with its process group), removes \
            these temporary files and directories and exits with 128 + the signal number; an \
            output already renamed into place keeps its new content. Temporary files are also \
            removed on errors. A SIGKILL of l2dat (or a crash) can leave them behind: remove \
            them with rm <directory>/.l2dat-*.tmp once no l2dat is running there, after checking \
            that one is not the only copy of an output you need. A SIGINT, SIGTERM or SIGHUP that \
            arrives in the first milliseconds, while a temporary file is being created, can also \
            leave one empty .l2dat-*.tmp behind; remove it the same way.

            On Linux, names of files that do not exist yet are compared case-sensitively: on a \
            case-insensitive mount (vfat, exfat, casefold) two new outputs of one command whose \
            names differ only in letter case (e.g. the txt and the -e export) are not recognised \
            as the same file. Existing files are compared by device and inode everywhere.
            """,
        version: L2DatVersion.string,
        subcommands: subcommands
    )

    private static var subcommands: [any ParsableCommand.Type] {
        #if DEBUG
        return [
            DecodeCommand.self, EncodeCommand.self, DisasmCommand.self, AsmCommand.self,
            OpenCommand.self, SaveCommand.self, RoundtripCommand.self, CorpusCommand.self,
            SelfTestPathsCommand.self,
        ]
        #else
        return [
            DecodeCommand.self, EncodeCommand.self, DisasmCommand.self, AsmCommand.self,
            OpenCommand.self, SaveCommand.self, RoundtripCommand.self, CorpusCommand.self,
        ]
        #endif
    }
}
