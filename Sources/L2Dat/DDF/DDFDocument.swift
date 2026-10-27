/// A parsed DDF file: control variables plus the field list, identifiers unresolved.
public struct DDFDocument: Sendable, Equatable {
    public var fileName: String
    public var controls: DDFControls
    public var fields: [DDFField]

    public init(fileName: String, controls: DDFControls = DDFControls(), fields: [DDFField] = []) {
        self.fileName = fileName
        self.controls = controls
        self.fields = fields
    }
}
