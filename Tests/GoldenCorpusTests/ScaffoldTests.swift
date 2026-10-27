import Foundation
import Testing
import TestSupport

@Test func repoRootResolvesToPackage() {
    #expect(FileManager.default.fileExists(atPath: RepoPaths.root.appendingPathComponent("Package.swift").path))
}
