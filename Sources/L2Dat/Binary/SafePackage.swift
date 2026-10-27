/// The `.dat` end marker: compact length 12 + "SafePackage\0".
enum SafePackage {
    static let marker: [UInt8] = [0x0C] + Array("SafePackage".utf8) + [0x00]
}
