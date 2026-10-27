import Foundation
import SwiftUI

/// Starts the SwiftUI app, or in DEBUG builds runs `--selftest <file> [<ddf>]` and exits.
@main
@MainActor
enum EntryPoint {
    static func main() {
        #if DEBUG
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--selftest") {
            let rest = Array(arguments[(index + 1)...])
            Task { exit(await SelfTest.run(rest)) }
            dispatchMain()
        }
        #endif
        L2FileEditorApp.main()
    }
}
