import Foundation

/// Record metadata defining schema and indexes
///
/// RecordMetaData is the central schema definition for a record store.
/// It contains all record types, indexes, and schema version information.
public struct RecordMetaData: Sendable {
    // MARK: - Properties

    /// Version number for schema evolution
    public let version: Int

    /// All record types in this metadata (keyed by name)
    public let recordTypes: [String: RecordType]

    /// All indexes (keyed by name)
    public let indexes: [String: Index]

    // MARK: - Initialization

    internal init(
        version: Int,
        recordTypes: [String: RecordType],
        indexes: [String: Index]
    ) {
        self.version = version
        self.recordTypes = recordTypes
        self.indexes = indexes
    }

    // MARK: - Public Methods

    /// Get a record type by name
    /// - Parameter name: The record type name
    /// - Returns: The record type
    /// - Throws: RecordLayerError.recordTypeNotFound if not found
    public func getRecordType(_ name: String) throws -> RecordType {
        guard let recordType = recordTypes[name] else {
            throw RecordLayerError.recordTypeNotFound(name)
        }
        return recordType
    }

    /// Get an index by name
    /// - Parameter name: The index name
    /// - Returns: The index
    /// - Throws: RecordLayerError.indexNotFound if not found
    public func getIndex(_ name: String) throws -> Index {
        guard let index = indexes[name] else {
            throw RecordLayerError.indexNotFound(name)
        }
        return index
    }

    /// Get all indexes that apply to a specific record type
    /// - Parameter recordTypeName: The record type name
    /// - Returns: Array of indexes
    public func getIndexesForRecordType(_ recordTypeName: String) -> [Index] {
        return indexes.values.filter { index in
            // Universal indexes (recordTypes == nil) apply to all types
            guard let recordTypes = index.recordTypes else {
                return true
            }
            // Otherwise check if this record type is in the index's set
            return recordTypes.contains(recordTypeName)
        }
    }
}

// MARK: - RecordMetaData Builder

/// Builder for constructing RecordMetaData
///
/// Provides a fluent API for building metadata with validation.
public class RecordMetaDataBuilder {
    private var version: Int = 1
    private var recordTypes: [RecordType] = []
    private var indexes: [Index] = []

    public init() {}

    /// Set the schema version
    /// - Parameter version: The version number
    /// - Returns: Self for chaining
    public func setVersion(_ version: Int) -> Self {
        self.version = version
        return self
    }

    /// Add a record type
    /// - Parameter recordType: The record type to add
    /// - Returns: Self for chaining
    public func addRecordType(_ recordType: RecordType) -> Self {
        recordTypes.append(recordType)
        return self
    }

    /// Add an index
    /// - Parameter index: The index to add
    /// - Returns: Self for chaining
    public func addIndex(_ index: Index) -> Self {
        indexes.append(index)
        return self
    }

    /// Build the RecordMetaData
    /// - Returns: The constructed metadata
    /// - Throws: RecordLayerError if validation fails
    public func build() throws -> RecordMetaData {
        // Validate record types are unique
        let typeNames = recordTypes.map { $0.name }
        let uniqueTypeNames = Set(typeNames)
        guard typeNames.count == uniqueTypeNames.count else {
            throw RecordLayerError.internalError("Duplicate record type names")
        }

        // Validate index names are unique
        let indexNames = indexes.map { $0.name }
        let uniqueIndexNames = Set(indexNames)
        guard indexNames.count == uniqueIndexNames.count else {
            throw RecordLayerError.internalError("Duplicate index names")
        }

        // Convert arrays to dictionaries
        let recordTypesDict = Dictionary(uniqueKeysWithValues: recordTypes.map { ($0.name, $0) })
        let indexesDict = Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) })

        return RecordMetaData(
            version: version,
            recordTypes: recordTypesDict,
            indexes: indexesDict
        )
    }
}
