import Foundation

// MARK: - SchemaProperty Protocol

/// SchemaProperty protocol (SwiftData compatible)
///
/// Common interface for Attribute and Relationship
public protocol SchemaProperty: Sendable {
    /// Property name
    var propertyName: String { get }
}

// MARK: - Schema.Entity

extension Schema {
    /// Entity - Blueprint for model class
    ///
    /// Corresponds to SwiftData's Schema.Entity:
    /// - Attributes
    /// - Relationships
    /// - Indices
    /// - Uniqueness constraints
    ///
    /// **Example usage**:
    /// ```swift
    /// let entity = schema.entity(for: User.self)
    /// print("Entity: \(entity?.name ?? "not found")")
    /// print("Indices: \(entity?.indices ?? [])")
    /// ```
    public final class Entity: Sendable, CustomDebugStringConvertible {

        // MARK: - Identity

        /// Entity name (type name)
        public let name: String

        // MARK: - Properties

        /// Attributes (placeholder - future implementation)
        public let attributes: Set<Attribute>

        /// Access attributes by name
        public let attributesByName: [String: Attribute]

        /// Relationships (future implementation)
        public let relationships: Set<Relationship>

        /// Access relationships by name
        public let relationshipsByName: [String: Relationship]

        /// All properties (attributes + relationships)
        public var properties: [any SchemaProperty] {
            return Array(attributes) + Array(relationships)
        }

        /// Stored properties (excluding transient)
        public var storedProperties: [any SchemaProperty] {
            // Future implementation: Filter transient attributes
            return properties
        }

        /// Access stored properties by name
        public var storedPropertiesByName: [String: any SchemaProperty] {
            var result: [String: any SchemaProperty] = [:]
            for property in storedProperties {
                result[property.propertyName] = property
            }
            return result
        }

        // MARK: - Constraints (SwiftData compatible)

        /// Indices (array of field names)
        ///
        /// Example:
        /// ```
        /// [["email"], ["city", "age"]]
        /// ```
        public let indices: [[String]]

        /// Uniqueness constraints (array of field names)
        ///
        /// Example:
        /// ```
        /// [["email"]]
        /// ```
        public let uniquenessConstraints: [[String]]

        // MARK: - Inheritance (future implementation)

        /// Parent entity (inheritance)
        public let superentity: Entity?

        /// Parent entity name
        public let superentityName: String?

        /// Child entities (inheritance)
        public let subentities: Set<Entity>

        // MARK: - FoundationDB extension (schema definition only)

        /// Primary key fields (field names only, no KeyExpression)
        public let primaryKeyFields: [String]

        /// Primary key expression (built from primaryKeyFields)
        ///
        /// This is the canonical KeyExpression used for:
        /// - Union/Intersection plans
        /// - Primary key extraction
        /// - Query planning
        ///
        /// **IMPORTANT**: This must match the structure returned by Recordable.extractPrimaryKey()
        public let primaryKeyExpression: KeyExpression

        // MARK: - Initialization

        /// Initialize Entity from Recordable type
        ///
        /// Builds Entity with schema definition only (no Index implementation objects).
        /// Tries to use the new type-safe API (`primaryKeyPaths`) first, then falls back
        /// to the old API (`primaryKeyFields`) for backward compatibility.
        internal init<T: Recordable>(from type: T.Type) {
            self.name = type.recordName

            // Try new API first (Phase 3: Migration to type-safe primary keys)
            if let primaryKeyPaths = type.primaryKeyPaths {
                // OK: Use KeyPath-based definition (compile-time safe)
                self.primaryKeyFields = primaryKeyPaths.fieldNames
                self.primaryKeyExpression = primaryKeyPaths.keyExpression

                // ALWAYS validate consistency (not just DEBUG)
                // This catches inconsistent implementations in production
                let allFieldsSet = Set(type.allFields)
                let invalidFields = primaryKeyFields.filter { !allFieldsSet.contains($0) }
                if !invalidFields.isEmpty {
                    fatalError("""
                        ERROR: FATAL: Invalid primary key fields in \(type.recordName)
                           Primary key fields not in allFields: \(invalidFields)
                           allFields: \(type.allFields)
                        """)
                }
            } else {
                // OK: Fallback to old API (manual definition)
                self.primaryKeyFields = type.primaryKeyFields

                // Validate that primaryKeyFields are valid (ALWAYS, not just DEBUG)
                let allFieldsSet = Set(type.allFields)
                let invalidFields = primaryKeyFields.filter { !allFieldsSet.contains($0) }
                if !invalidFields.isEmpty {
                    fatalError("""
                        ERROR: FATAL: Invalid primary key fields in \(type.recordName)
                           Primary key fields not in allFields: \(invalidFields)
                           allFields: \(type.allFields)
                        """)
                }

                // Validate not empty
                if primaryKeyFields.isEmpty {
                    fatalError("""
                        ERROR: FATAL: Empty primary key fields in \(type.recordName)
                           Must define at least one primary key field.
                        """)
                }

                // Build primary key expression from primaryKeyFields
                // This assumes primary keys are simple FieldKeyExpressions
                self.primaryKeyExpression = if primaryKeyFields.count == 1 {
                    FieldKeyExpression(fieldName: primaryKeyFields[0])
                } else {
                    ConcatenateKeyExpression(children: primaryKeyFields.map { FieldKeyExpression(fieldName: $0) })
                }
            }

            // Build attributes from Recordable.allFields
            let allFields = type.allFields
            var attributes: Set<Attribute> = []
            var attributesByName: [String: Attribute] = [:]

            for fieldName in allFields {
                let isPrimaryKey = primaryKeyFields.contains(fieldName)

                // Extract enum metadata if available
                let enumMetadata = type.enumMetadata(for: fieldName)

                let attribute = Attribute(
                    name: fieldName,
                    isOptional: false,  // Future: detect from type reflection
                    isPrimaryKey: isPrimaryKey,
                    enumMetadata: enumMetadata
                )
                attributes.insert(attribute)
                attributesByName[fieldName] = attribute
            }

            self.attributes = attributes
            self.attributesByName = attributesByName

            // Relationships (future implementation)
            self.relationships = []
            self.relationshipsByName = [:]

            // Indices & uniqueness constraints
            // Extract from type's indexDefinitions
            var regularIndices: [[String]] = []
            var uniqueConstraints: [[String]] = []

            for indexDef in type.indexDefinitions {
                if indexDef.unique {
                    uniqueConstraints.append(indexDef.fields)
                } else {
                    regularIndices.append(indexDef.fields)
                }
            }

            self.indices = regularIndices
            self.uniquenessConstraints = uniqueConstraints

            // Inheritance (future implementation)
            self.superentity = nil
            self.superentityName = nil
            self.subentities = []
        }

        /// Test-only initializer for manual Entity construction
        ///
        /// Allows creating Entity objects with custom attributes for testing purposes.
        /// This is primarily used for schema evolution validation tests where we need
        /// to construct entities with specific enum metadata.
        ///
        /// - Parameters:
        ///   - name: Entity name
        ///   - attributes: Array of attributes
        public init(name: String, attributes: [Attribute]) {
            self.name = name
            self.attributes = Set(attributes)

            // Build attributes by name map
            var attributesByName: [String: Attribute] = [:]
            for attribute in attributes {
                attributesByName[attribute.name] = attribute
            }
            self.attributesByName = attributesByName

            // Extract primary key fields
            self.primaryKeyFields = attributes.filter { $0.isPrimaryKey }.map { $0.name }

            // For test entities, create a simple primary key expression
            let primaryKeyExpression: KeyExpression
            if primaryKeyFields.count == 1 {
                primaryKeyExpression = FieldKeyExpression(fieldName: primaryKeyFields[0])
            } else if primaryKeyFields.count > 1 {
                primaryKeyExpression = ConcatenateKeyExpression(
                    children: primaryKeyFields.map { FieldKeyExpression(fieldName: $0) }
                )
            } else {
                // No primary key specified - should not happen in real use
                primaryKeyExpression = FieldKeyExpression(fieldName: "id")
            }
            self.primaryKeyExpression = primaryKeyExpression

            // Empty relationships for test entities
            self.relationships = Set()
            self.relationshipsByName = [:]

            // No indices for test entities
            self.indices = []
            self.uniquenessConstraints = []

            // No inheritance
            self.superentity = nil
            self.superentityName = nil
            self.subentities = []
        }

        // MARK: - CustomDebugStringConvertible

        public var debugDescription: String {
            return "Entity(name: \(name), primaryKey: \(primaryKeyFields), indices: \(indices.count))"
        }
    }

    // MARK: - EnumMetadata

    /// Metadata for enum fields
    ///
    /// Captures enum type information for schema evolution validation.
    /// Only populated for fields with CaseIterable enum types.
    ///
    /// **Example**:
    /// ```swift
    /// enum Status: String, CaseIterable {
    ///     case active, inactive, archived
    /// }
    ///
    /// // EnumMetadata captured:
    /// EnumMetadata(
    ///     typeName: "Status",
    ///     cases: ["active", "inactive", "archived"]
    /// )
    /// ```
    public struct EnumMetadata: Sendable, Hashable {
        /// Enum type name (e.g., "ProductStatus")
        public let typeName: String

        /// Enum case names in declaration order
        /// For String raw values: ["active", "inactive"]
        /// For Int raw values: ["0", "1", "2"]
        /// For no raw value: ["case1", "case2"]
        public let cases: [String]

        public init(typeName: String, cases: [String]) {
            self.typeName = typeName
            self.cases = cases
        }
    }

    // MARK: - Attribute

    /// Attribute (field)
    ///
    /// Corresponds to SwiftData's Schema.Attribute
    public struct Attribute: Sendable, Hashable, SchemaProperty {
        /// Attribute name
        public let name: String

        /// Whether optional
        public let isOptional: Bool

        /// Whether primary key
        public let isPrimaryKey: Bool

        /// Enum metadata (nil for non-enum fields)
        ///
        /// Only populated if:
        /// 1. Field type is an enum
        /// 2. Enum conforms to CaseIterable
        /// 3. Recordable.enumMetadata(for:) returns metadata
        public let enumMetadata: EnumMetadata?

        // SchemaProperty conformance
        public var propertyName: String { name }

        public init(
            name: String,
            isOptional: Bool = false,
            isPrimaryKey: Bool = false,
            enumMetadata: EnumMetadata? = nil
        ) {
            self.name = name
            self.isOptional = isOptional
            self.isPrimaryKey = isPrimaryKey
            self.enumMetadata = enumMetadata
        }
    }

    // MARK: - Relationship

    /// Relationship (future implementation)
    ///
    /// Corresponds to SwiftData's Schema.Relationship
    public struct Relationship: Sendable, Hashable, SchemaProperty {
        /// Relationship name
        public let name: String

        /// Destination entity name
        public let destinationEntityName: String

        /// Delete rule
        public let deleteRule: DeleteRule

        /// Whether to-many relationship
        public let isToMany: Bool

        /// Inverse relationship name (optional)
        public let inverseRelationshipName: String?

        // SchemaProperty conformance
        public var propertyName: String { name }

        /// Delete rule
        public enum DeleteRule: Sendable, Hashable {
            /// Nullify rule (set to nil)
            case nullify
            /// Cascade rule (delete related objects)
            case cascade
            /// Deny rule (prevent deletion)
            case deny
        }

        internal init(
            name: String,
            destinationEntityName: String,
            deleteRule: DeleteRule,
            isToMany: Bool,
            inverseRelationshipName: String? = nil
        ) {
            self.name = name
            self.destinationEntityName = destinationEntityName
            self.deleteRule = deleteRule
            self.isToMany = isToMany
            self.inverseRelationshipName = inverseRelationshipName
        }
    }
}

// MARK: - Schema.Entity Equatable & Hashable

extension Schema.Entity: Equatable {
    public static func == (lhs: Schema.Entity, rhs: Schema.Entity) -> Bool {
        return lhs.name == rhs.name
    }
}

extension Schema.Entity: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

// MARK: - KeyExpression Helper

extension KeyExpression {
    /// Extract field names from KeyExpression
    /// This is a utility method for Schema.Entity to extract index field names
    public func fieldNames() -> [String] {
        if let field = self as? FieldKeyExpression {
            return [field.fieldName]
        } else if let concat = self as? ConcatenateKeyExpression {
            return concat.children.flatMap { $0.fieldNames() }
        }
        // For other expression types, return empty array
        return []
    }
}
