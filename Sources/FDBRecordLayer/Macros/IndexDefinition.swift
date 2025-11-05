import Foundation

/// Definition of an index created by #Index or #Unique macros
///
/// This type holds the metadata for indexes defined using macros.
/// The RecordMetaData will collect these definitions and register them.
public struct IndexDefinition: Sendable {
    /// The name of the index
    public let name: String

    /// The record type this index applies to
    public let recordType: String

    /// The fields included in this index
    public let fields: [String]

    /// Whether this index enforces uniqueness
    public let unique: Bool

    /// Initialize an index definition
    ///
    /// - Parameters:
    ///   - name: The name of the index
    ///   - recordType: The record type this index applies to
    ///   - fields: The fields included in this index
    ///   - unique: Whether this index enforces uniqueness
    public init(name: String, recordType: String, fields: [String], unique: Bool) {
        self.name = name
        self.recordType = recordType
        self.fields = fields
        self.unique = unique
    }
}
