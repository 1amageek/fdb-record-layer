import Foundation

/// Lightweight Migration Support
///
/// Provides automatic schema evolution for simple changes.
extension MigrationManager {
    /// Perform lightweight migration between two schemas
    ///
    /// Lightweight migrations handle simple schema changes automatically:
    /// - ✅ Adding new record types
    /// - ✅ Adding new indexes
    /// - ✅ Adding optional fields (with default values)
    ///
    /// **Not supported** (requires custom migration):
    /// - ❌ Removing record types
    /// - ❌ Removing fields
    /// - ❌ Changing field types
    /// - ❌ Data transformation
    ///
    /// **Example**:
    /// ```swift
    /// let migration = MigrationManager.lightweightMigration(
    ///     from: SchemaV1.self,
    ///     to: SchemaV2.self
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - fromSchema: Source schema
    ///   - toSchema: Target schema
    /// - Returns: Migration instance
    public static func lightweightMigration(
        from fromSchema: any VersionedSchema.Type,
        to toSchema: any VersionedSchema.Type
    ) -> Migration {
        let fromVersion = SchemaVersion(
            major: fromSchema.versionIdentifier.major,
            minor: fromSchema.versionIdentifier.minor,
            patch: fromSchema.versionIdentifier.patch
        )
        let toVersion = SchemaVersion(
            major: toSchema.versionIdentifier.major,
            minor: toSchema.versionIdentifier.minor,
            patch: toSchema.versionIdentifier.patch
        )

        return Migration(
            fromVersion: fromVersion,
            toVersion: toVersion,
            description: "Lightweight migration: \(fromVersion) → \(toVersion)"
        ) { context in
            // 1. Detect schema changes
            let fromSchemaObj = Schema(versionedSchema: fromSchema)
            let toSchemaObj = Schema(versionedSchema: toSchema)

            let changes = detectSchemaChanges(from: fromSchemaObj, to: toSchemaObj)

            // 2. Validate lightweight migration is possible
            guard changes.canBeAutomatic else {
                throw RecordLayerError.internalError(
                    "Cannot perform lightweight migration: " +
                    changes.unsupportedChanges.joined(separator: ", ")
                )
            }

            // 3. Apply changes automatically
            for indexToAdd in changes.indexesToAdd {
                try await context.addIndex(indexToAdd)
            }

            // New record types are automatically supported (no migration needed)
            // Optional fields with defaults are automatically supported
        }
    }

    // MARK: - Schema Change Detection

    /// Schema changes detected between two versions
    private struct SchemaChanges {
        let indexesToAdd: [Index]
        let indexesToRemove: [String]
        let newRecordTypes: [String]
        let unsupportedChanges: [String]

        var canBeAutomatic: Bool {
            return unsupportedChanges.isEmpty
        }
    }

    /// Detect changes between two schemas
    ///
    /// - Parameters:
    ///   - oldSchema: Source schema
    ///   - newSchema: Target schema
    /// - Returns: Schema changes
    private static func detectSchemaChanges(
        from oldSchema: Schema,
        to newSchema: Schema
    ) -> SchemaChanges {
        var indexesToAdd: [Index] = []
        var indexesToRemove: [String] = []
        var newRecordTypes: [String] = []
        var unsupportedChanges: [String] = []

        // Detect new indexes
        for index in newSchema.indexes {
            if oldSchema.index(named: index.name) == nil {
                indexesToAdd.append(index)
            }
        }

        // Detect removed indexes (requires custom migration)
        for index in oldSchema.indexes {
            if newSchema.index(named: index.name) == nil {
                indexesToRemove.append(index.name)
                unsupportedChanges.append(
                    "Index '\(index.name)' removed (requires custom migration with removeIndex())"
                )
            }
        }

        // Detect new record types (automatically supported)
        for entity in newSchema.entities {
            if oldSchema.entity(named: entity.name) == nil {
                newRecordTypes.append(entity.name)
            }
        }

        // Detect removed record types (not supported)
        for entity in oldSchema.entities {
            if newSchema.entity(named: entity.name) == nil {
                unsupportedChanges.append(
                    "Record type '\(entity.name)' removed (not supported in lightweight migration)"
                )
            }
        }

        // TODO: Detect field changes (requires Entity.properties comparison)
        // For now, field changes are not validated

        return SchemaChanges(
            indexesToAdd: indexesToAdd,
            indexesToRemove: indexesToRemove,
            newRecordTypes: newRecordTypes,
            unsupportedChanges: unsupportedChanges
        )
    }
}
