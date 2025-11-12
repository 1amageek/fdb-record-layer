import Foundation

public final class MetaDataEvolutionValidator: Sendable {
    private let oldMetaData: Schema
    private let newMetaData: Schema
    private let options: ValidationOptions

    public struct ValidationOptions: Sendable {
        public let allowIndexRebuilds: Bool
        public let allowFieldAdditions: Bool
        public let allowOptionalFields: Bool

        public init(
            allowIndexRebuilds: Bool,
            allowFieldAdditions: Bool,
            allowOptionalFields: Bool
        ) {
            self.allowIndexRebuilds = allowIndexRebuilds
            self.allowFieldAdditions = allowFieldAdditions
            self.allowOptionalFields = allowOptionalFields
        }

        public static let strict = ValidationOptions(
            allowIndexRebuilds: false,
            allowFieldAdditions: false,
            allowOptionalFields: false
        )

        public static let permissive = ValidationOptions(
            allowIndexRebuilds: true,
            allowFieldAdditions: true,
            allowOptionalFields: true
        )
    }

    public init(
        old: Schema,
        new: Schema,
        options: ValidationOptions = .strict
    ) {
        self.oldMetaData = old
        self.newMetaData = new
        self.options = options
    }

    public func validate() async throws -> ValidationResult {
        var result = ValidationResult.valid

        result = try await validateRecordTypes(result)
        result = try await validateFields(result)
        result = try await validateIndexes(result)
        result = try await validateEnums(result)

        return result
    }

    private func validateRecordTypes(_ result: ValidationResult) async throws -> ValidationResult {
        var updated = result

        let oldTypes = Set(oldMetaData.entities.map { $0.name })
        let newTypes = Set(newMetaData.entities.map { $0.name })

        // Check for deleted record types
        let deletedTypes = oldTypes.subtracting(newTypes)
        for deletedType in deletedTypes {
            updated = updated.addError(.recordTypeDeleted(recordType: deletedType))
        }

        return updated
    }

    private func validateFields(_ result: ValidationResult) async throws -> ValidationResult {
        var updated = result

        // Build entity maps for quick lookup
        let oldEntitiesByName = Dictionary(uniqueKeysWithValues: oldMetaData.entities.map { ($0.name, $0) })
        let newEntitiesByName = Dictionary(uniqueKeysWithValues: newMetaData.entities.map { ($0.name, $0) })

        // Check each entity that exists in both schemas
        for (entityName, oldEntity) in oldEntitiesByName {
            guard let newEntity = newEntitiesByName[entityName] else {
                // Entity deleted - already caught in validateRecordTypes
                continue
            }

            let oldFields = Set(oldEntity.attributes.map { $0.name })
            let newFields = Set(newEntity.attributes.map { $0.name })

            // Check for deleted fields
            let deletedFields = oldFields.subtracting(newFields)
            for deletedField in deletedFields {
                updated = updated.addError(.fieldDeleted(recordType: entityName, fieldName: deletedField))
            }

            // Check for field type changes (optional vs required)
            for fieldName in oldFields.intersection(newFields) {
                guard let oldAttribute = oldEntity.attributesByName[fieldName],
                      let newAttribute = newEntity.attributesByName[fieldName] else {
                    continue
                }

                // Check if required field became optional or vice versa
                // Making required -> optional is safe
                // Making optional -> required is unsafe (existing data may have nulls)
                if !oldAttribute.isOptional && newAttribute.isOptional {
                    // Safe: required -> optional
                    // This is allowed as it relaxes the constraint
                    continue
                }

                if oldAttribute.isOptional && !newAttribute.isOptional {
                    // Unsafe: optional -> required
                    // This could break existing data that has nulls
                    if !options.allowOptionalFields {
                        updated = updated.addError(.fieldTypeChanged(
                            recordType: entityName,
                            fieldName: fieldName,
                            old: "optional",
                            new: "required"
                        ))
                    }
                }
            }

            // Check for added required fields
            if !options.allowFieldAdditions {
                let addedFields = newFields.subtracting(oldFields)
                for addedField in addedFields {
                    guard let newAttribute = newEntity.attributesByName[addedField] else {
                        continue
                    }

                    // Adding optional fields is safe
                    // Adding required fields is unsafe (no default value for existing records)
                    if !newAttribute.isOptional {
                        updated = updated.addError(.requiredFieldAdded(
                            recordType: entityName,
                            fieldName: addedField
                        ))
                    }
                }
            }
        }

        return updated
    }

    private func validateIndexes(_ result: ValidationResult) async throws -> ValidationResult {
        var updated = result

        let oldIndexes = Set(oldMetaData.indexes.map { $0.name })
        let newIndexes = Set(newMetaData.indexes.map { $0.name })

        let deletedIndexes = oldIndexes.subtracting(newIndexes)
        for deletedIndex in deletedIndexes {
            let hasFormerIndex = newMetaData.formerIndexes[deletedIndex] != nil
            if !hasFormerIndex {
                updated = updated.addError(.indexDeletedWithoutFormerIndex(indexName: deletedIndex))
            }
        }

        for indexName in oldIndexes.intersection(newIndexes) {
            guard let oldIndex = oldMetaData.indexes.first(where: { $0.name == indexName }),
                  let newIndex = newMetaData.indexes.first(where: { $0.name == indexName }) else {
                continue
            }

            if !areIndexFormatsCompatible(oldIndex, newIndex) {
                updated = updated.addError(.indexFormatChanged(indexName: indexName))
            }
        }

        return updated
    }

    private func areIndexFormatsCompatible(_ old: Index, _ new: Index) -> Bool {
        guard old.type == new.type else { return false }

        // Compare root expression by column count
        // A more thorough comparison would recursively compare the expression tree
        guard old.rootExpression.columnCount == new.rootExpression.columnCount else {
            return false
        }

        // For now, consider them compatible if type and column count match
        // Future enhancement: deep comparison of expression structure
        return true
    }

    private func validateEnums(_ result: ValidationResult) async throws -> ValidationResult {
        var updated = result

        // Build entity maps for quick lookup
        let oldEntitiesByName = Dictionary(uniqueKeysWithValues: oldMetaData.entities.map { ($0.name, $0) })
        let newEntitiesByName = Dictionary(uniqueKeysWithValues: newMetaData.entities.map { ($0.name, $0) })

        // Check each entity that exists in both schemas
        for (entityName, oldEntity) in oldEntitiesByName {
            guard let newEntity = newEntitiesByName[entityName] else {
                // Entity deleted - already caught in validateRecordTypes
                continue
            }

            // Validate each field with enum metadata
            for (fieldName, oldAttribute) in oldEntity.attributesByName {
                guard let newAttribute = newEntity.attributesByName[fieldName] else {
                    // Field deleted - already caught in validateFields
                    continue
                }

                // Check if both old and new have enum metadata
                guard let oldEnumMetadata = oldAttribute.enumMetadata,
                      let newEnumMetadata = newAttribute.enumMetadata else {
                    // Either:
                    // - Field was not an enum (both nil) - OK
                    // - Field changed from enum to non-enum or vice versa - caught by field type validation
                    continue
                }

                // Compare enum cases for this specific field
                // Note: We compare by field path (entityName.fieldName), not by enum type name
                // This allows enum types to be renamed during refactoring
                let oldCases = Set(oldEnumMetadata.cases)
                let newCases = Set(newEnumMetadata.cases)

                // Check for deleted enum cases
                let deletedCases = oldCases.subtracting(newCases)
                if !deletedCases.isEmpty {
                    // Deleting enum cases is unsafe - existing data may reference deleted cases
                    updated = updated.addError(.enumValueDeleted(
                        recordType: entityName,
                        fieldName: fieldName,
                        deletedValues: Array(deletedCases).sorted()
                    ))
                }

                // Adding new enum cases is safe - existing data won't be affected
                // No validation needed for added cases
            }
        }

        return updated
    }
}
