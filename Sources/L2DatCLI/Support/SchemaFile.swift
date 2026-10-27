import Foundation
import L2Dat

/// Loads a DDF file into a resolved `Schema`; errors name the DDF by its file name.
enum SchemaFile {
    static func load(_ url: URL) throws -> Schema {
        try Schema(DDF.parse(try FileIO.read(url), fileName: url.lastPathComponent))
    }
}
