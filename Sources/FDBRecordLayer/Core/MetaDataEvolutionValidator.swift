import Foundation

/// Validates schema evolution to ensure safe and compatible changes
///
/// MetaDataEvolutionValidator checks that changes between schema versions
/// maintain backward compatibility and follow safe evolution patterns.
///
/// **Validation Rules**:
/// 1. **Record Types**: Cannot be removed
/// 2. **Fields**: Cannot be removed or change type incompatibly
/// 3. **Indexes**: Cannot change disk format, must use FormerIndex when removed
/// 4. **Primary Keys**: Cannot change structure
///
/// **Usage**:
/// ```swift
/// let validator = try MetaDataEvolutionValidator(
///     oldMetaData: oldMetaData,
///     newMetaData: newMetaData,
///     allowIndexRebuilds: true
/// )
///
/// try validator.validate()
/// ```
///
/// **Design Reference**: Based on Java Record Layer's MetaDataEvolutionValidator
public final class MetaDataEvolutionValidator: Sendable {
    // MARK: - Nested Types

    /// Validation error representing an incompatible schema change
    public struct ValidationError: Error, Sendable, CustomStringConvertible {
        public enum Category: String, Sendable {
            case recordTypeRemoved = "Record type removed"
            case fieldRemoved = "Field removed"
            case fieldTypeChanged = "Field type changed incompatibly"
            case primaryKeyChanged = "Primary key changed"
            case indexFormatChanged = "Index format changed"
            case indexRemovedWithoutFormer = "Index removed without FormerIndex"
            case formerIndexConflict = "FormerIndex conflicts with new index"
            case formerIndexRemoved = "FormerIndex removed"
            case indexSubspaceConflict = "Index subspace conflict"
        }

        public let category: Category
        public let recordTypeName: String?
        public let fieldName: String?
        public let indexName: String?
        public let message: String

        public var description: String {
            var parts = ["[\(category.rawValue)]"]

            if let recordTypeName = recordTypeName {
                parts.append("RecordType: \(recordTypeName)")
            }
            if let fieldName = fieldName {
                parts.append("Field: \(fieldName)")
            }
            if let indexName = indexName {
                parts.append("Index: \(indexName)")
            }

            parts.append(message)

            return parts.joined(separator: " ")
        }

        init(
            category: Category,
            recordTypeName: String? = nil,
            fieldName: String? = nil,
            indexName: String? = nil,
            message: String
        ) {
            self.category = category
            self.recordTypeName = recordTypeName
            self.fieldName = fieldName
            self.indexName = indexName
            self.message = message
        }
    }

    /// Validation result containing all detected errors
    public struct ValidationResult: Sendable {
        public let isValid: Bool
        public let errors: [ValidationError]

        public var errorCount: Int { errors.count }

        public init(errors: [ValidationError]) {
            self.errors = errors
            self.isValid = errors.isEmpty
        }
    }

    // MARK: - Properties

    private let oldMetaData: RecordMetaData
    private let newMetaData: RecordMetaData
    private let allowIndexRebuilds: Bool

    // MARK: - Initialization

    /// Initialize a MetaDataEvolutionValidator
    ///
    /// - Parameters:
    ///   - oldMetaData: The previous schema version
    ///   - newMetaData: The new schema version to validate
    ///   - allowIndexRebuilds: If true, allows index changes that require rebuilding.
    ///                         If false, any index format change is an error.
    /// - Throws: RecordLayerError if parameters are invalid
    public init(
        oldMetaData: RecordMetaData,
        newMetaData: RecordMetaData,
        allowIndexRebuilds: Bool = false
    ) throws {
        // Validate version progression
        guard newMetaData.version >= oldMetaData.version else {
            throw RecordLayerError.internalError(
                "New metadata version (\(newMetaData.version)) must be >= old version (\(oldMetaData.version))"
            )
        }

        self.oldMetaData = oldMetaData
        self.newMetaData = newMetaData
        self.allowIndexRebuilds = allowIndexRebuilds
    }

    // MARK: - Validation

    /// Validate the schema evolution
    ///
    /// Performs all validation checks and returns a comprehensive result.
    ///
    /// - Returns: ValidationResult containing all detected errors
    public func validate() -> ValidationResult {
        var errors: [ValidationError] = []

        // 1. Validate record types
        errors.append(contentsOf: validateRecordTypes())

        // 2. Validate indexes
        errors.append(contentsOf: validateIndexes())

        // 3. Validate former indexes
        errors.append(contentsOf: validateFormerIndexes())

        return ValidationResult(errors: errors)
    }

    /// Validate the schema evolution and throw if invalid
    ///
    /// Convenience method that throws the first error if validation fails.
    ///
    /// - Throws: ValidationError if validation fails
    public func validateAndThrow() throws {
        let result = validate()
        if let firstError = result.errors.first {
            throw firstError
        }
    }

    // MARK: - Record Type Validation

    private func validateRecordTypes() -> [ValidationError] {
        var errors: [ValidationError] = []

        let oldRecordTypes = oldMetaData.recordTypes
        let newRecordTypes = newMetaData.recordTypes

        // Check for removed record types
        for (oldTypeName, oldType) in oldRecordTypes {
            guard let newType = newRecordTypes[oldTypeName] else {
                errors.append(ValidationError(
                    category: .recordTypeRemoved,
                    recordTypeName: oldTypeName,
                    message: "Record type '\(oldTypeName)' was removed. Record types cannot be removed."
                ))
                continue
            }

            // Validate fields within the record type
            errors.append(contentsOf: validateFields(
                oldType: oldType,
                newType: newType,
                recordTypeName: oldTypeName
            ))

            // Validate primary key hasn't changed
            if !areKeyExpressionsCompatible(oldType.primaryKey, newType.primaryKey) {
                errors.append(ValidationError(
                    category: .primaryKeyChanged,
                    recordTypeName: oldTypeName,
                    message: "Primary key structure changed for '\(oldTypeName)'"
                ))
            }
        }

        return errors
    }

    // MARK: - Field Validation

    private func validateFields(
        oldType: RecordType,
        newType: RecordType,
        recordTypeName: String
    ) -> [ValidationError] {
        var errors: [ValidationError] = []

        // For now, we only validate that the primary key fields are present
        // Full field validation would require Protobuf descriptor comparison,
        // which is more complex and will be implemented in a future phase.

        // Extract field names from primary key
        let oldPrimaryKeyFields = extractFieldNames(from: oldType.primaryKey)
        let newPrimaryKeyFields = extractFieldNames(from: newType.primaryKey)

        // Check that old primary key fields still exist
        for oldField in oldPrimaryKeyFields {
            if !newPrimaryKeyFields.contains(oldField) {
                errors.append(ValidationError(
                    category: .fieldRemoved,
                    recordTypeName: recordTypeName,
                    fieldName: oldField,
                    message: "Primary key field '\(oldField)' was removed from '\(recordTypeName)'"
                ))
            }
        }

        return errors
    }

    private func extractFieldNames(from keyExpression: KeyExpression) -> Set<String> {
        var fieldNames = Set<String>()

        func extract(_ expr: KeyExpression) {
            if let field = expr as? FieldKeyExpression {
                fieldNames.insert(field.fieldName)
            } else if let concat = expr as? ConcatenateKeyExpression {
                for child in concat.children {
                    extract(child)
                }
            } else if let nest = expr as? NestExpression {
                extract(nest.child)
            }
        }

        extract(keyExpression)
        return fieldNames
    }

    // MARK: - Index Validation

    private func validateIndexes() -> [ValidationError] {
        var errors: [ValidationError] = []

        let oldIndexes = oldMetaData.indexes
        let newIndexes = newMetaData.indexes
        let newFormerIndexes = newMetaData.formerIndexes

        // Check for removed indexes without FormerIndex
        for (oldIndexName, oldIndex) in oldIndexes {
            if let newIndex = newIndexes[oldIndexName] {
                // Index still exists, check compatibility
                errors.append(contentsOf: validateIndexCompatibility(
                    oldIndex: oldIndex,
                    newIndex: newIndex
                ))
            } else {
                // Index was removed, must have FormerIndex
                if !newFormerIndexes.keys.contains(oldIndexName) {
                    errors.append(ValidationError(
                        category: .indexRemovedWithoutFormer,
                        indexName: oldIndexName,
                        message: "Index '\(oldIndexName)' was removed without adding a FormerIndex"
                    ))
                }
            }
        }

        // Check for new indexes conflicting with former indexes
        let oldFormerIndexes = oldMetaData.formerIndexes

        for (newIndexName, _) in newIndexes {
            // Check if this name was a former index in old metadata
            if oldFormerIndexes.keys.contains(newIndexName) {
                errors.append(ValidationError(
                    category: .formerIndexConflict,
                    indexName: newIndexName,
                    message: "New index '\(newIndexName)' conflicts with a FormerIndex from previous version"
                ))
            }
        }

        return errors
    }

    private func validateIndexCompatibility(
        oldIndex: Index,
        newIndex: Index
    ) -> [ValidationError] {
        var errors: [ValidationError] = []

        // 1. Check index type hasn't changed
        if oldIndex.type != newIndex.type {
            if !allowIndexRebuilds {
                errors.append(ValidationError(
                    category: .indexFormatChanged,
                    indexName: oldIndex.name,
                    message: "Index type changed from \(oldIndex.type) to \(newIndex.type). Set allowIndexRebuilds=true to permit."
                ))
            }
        }

        // 2. Check root expression compatibility
        if !areKeyExpressionsCompatible(oldIndex.rootExpression, newIndex.rootExpression) {
            if !allowIndexRebuilds {
                errors.append(ValidationError(
                    category: .indexFormatChanged,
                    indexName: oldIndex.name,
                    message: "Index root expression changed. Set allowIndexRebuilds=true to permit."
                ))
            }
        }

        // 3. Check subspace key compatibility
        // If subspace keys are different, this changes the disk layout
        if !areSubspaceKeysCompatible(oldIndex.subspaceTupleKey, newIndex.subspaceTupleKey) {
            if !allowIndexRebuilds {
                errors.append(ValidationError(
                    category: .indexSubspaceConflict,
                    indexName: oldIndex.name,
                    message: "Index subspace key changed. Set allowIndexRebuilds=true to permit."
                ))
            }
        }

        return errors
    }

    // MARK: - FormerIndex Validation

    private func validateFormerIndexes() -> [ValidationError] {
        var errors: [ValidationError] = []

        let oldFormerIndexes = oldMetaData.formerIndexes
        let newIndexes = newMetaData.indexes
        let newFormerIndexes = newMetaData.formerIndexes

        // CRITICAL: Check that all old FormerIndexes are preserved in new metadata
        // FormerIndexes are permanent markers that must never be removed.
        // Removing them would allow the index name to be reused, potentially
        // causing conflicts with data from the previous index.
        for (oldFormerIndexName, oldFormerIndex) in oldFormerIndexes {
            if let newFormerIndex = newFormerIndexes[oldFormerIndexName] {
                // FormerIndex exists in new metadata, validate it hasn't changed
                if newFormerIndex.addedVersion != oldFormerIndex.addedVersion ||
                   newFormerIndex.removedVersion != oldFormerIndex.removedVersion {
                    errors.append(ValidationError(
                        category: .formerIndexRemoved,
                        indexName: oldFormerIndexName,
                        message: "FormerIndex '\(oldFormerIndexName)' version changed. " +
                                "addedVersion: \(oldFormerIndex.addedVersion) -> \(newFormerIndex.addedVersion), " +
                                "removedVersion: \(oldFormerIndex.removedVersion) -> \(newFormerIndex.removedVersion). " +
                                "FormerIndexes must remain unchanged."
                    ))
                }
            } else {
                // FormerIndex was removed from new metadata - this is an error
                errors.append(ValidationError(
                    category: .formerIndexRemoved,
                    indexName: oldFormerIndexName,
                    message: "FormerIndex '\(oldFormerIndexName)' was removed. " +
                            "FormerIndexes must be preserved across all schema versions to prevent name reuse conflicts."
                ))
            }
        }

        // Check that no active index has the same name as a former index in new metadata
        for (formerIndexName, _) in newFormerIndexes {
            if newIndexes.keys.contains(formerIndexName) {
                errors.append(ValidationError(
                    category: .formerIndexConflict,
                    indexName: formerIndexName,
                    message: "Active index '\(formerIndexName)' conflicts with a FormerIndex"
                ))
            }
        }

        return errors
    }

    // MARK: - Compatibility Helpers

    private func areKeyExpressionsCompatible(
        _ old: KeyExpression,
        _ new: KeyExpression
    ) -> Bool {
        // Basic structural comparison
        // In a full implementation, this would do deep comparison

        if type(of: old) != type(of: new) {
            return false
        }

        if let oldField = old as? FieldKeyExpression,
           let newField = new as? FieldKeyExpression {
            return oldField.fieldName == newField.fieldName
        }

        if let oldConcat = old as? ConcatenateKeyExpression,
           let newConcat = new as? ConcatenateKeyExpression {
            guard oldConcat.children.count == newConcat.children.count else {
                return false
            }
            return zip(oldConcat.children, newConcat.children).allSatisfy { pair in
                areKeyExpressionsCompatible(pair.0, pair.1)
            }
        }

        if let oldNest = old as? NestExpression,
           let newNest = new as? NestExpression {
            return oldNest.parentField == newNest.parentField &&
                   areKeyExpressionsCompatible(oldNest.child, newNest.child)
        }

        // EmptyKeyExpression
        if old is EmptyKeyExpression && new is EmptyKeyExpression {
            return true
        }

        // Unknown types: assume compatible for now
        return true
    }

    private func areSubspaceKeysCompatible(
        _ old: (any TupleElement)?,
        _ new: (any TupleElement)?
    ) -> Bool {
        // If both are nil, they're compatible
        if old == nil && new == nil {
            return true
        }

        // If one is nil and the other isn't, incompatible
        guard let oldKey = old, let newKey = new else {
            return false
        }

        // Compare string representations
        // This is a simplified check; full implementation would compare actual values
        return String(describing: oldKey) == String(describing: newKey)
    }
}

// MARK: - Convenience Methods

extension MetaDataEvolutionValidator {
    /// Create a validator and immediately validate
    ///
    /// - Parameters:
    ///   - oldMetaData: The previous schema version
    ///   - newMetaData: The new schema version to validate
    ///   - allowIndexRebuilds: If true, allows index changes that require rebuilding
    /// - Returns: ValidationResult
    /// - Throws: RecordLayerError if parameters are invalid
    public static func validateEvolution(
        from oldMetaData: RecordMetaData,
        to newMetaData: RecordMetaData,
        allowIndexRebuilds: Bool = false
    ) throws -> ValidationResult {
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData,
            allowIndexRebuilds: allowIndexRebuilds
        )
        return validator.validate()
    }
}
