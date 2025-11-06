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

        // MARK: - Constraints

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

        // MARK: - Internal

        /// Internal: RecordType (compatibility with existing implementation)
        internal let recordType: RecordType

        /// Internal: Associated Index objects
        internal let indexObjects: [Index]

        // MARK: - Initialization

        internal init(
            name: String,
            recordType: RecordType,
            metaData: RecordMetaData
        ) {
            self.name = name
            self.recordType = recordType

            // Attributes (simplified - no field extraction for now)
            // Future: Extract actual field information from Recordable type
            self.attributes = []
            self.attributesByName = [:]

            // Relationships (future implementation)
            self.relationships = []
            self.relationshipsByName = [:]

            // Extract indices from metaData
            let indexes = metaData.getIndexesForRecordType(name)
            self.indexObjects = indexes

            var indices: [[String]] = []
            for index in indexes {
                // Extract field names from KeyExpression
                let fieldNames = index.rootExpression.fieldNames()
                indices.append(fieldNames)
            }
            self.indices = indices

            // Extract unique constraints
            var uniquenessConstraints: [[String]] = []
            for index in indexes where index.options.unique {
                let fieldNames = index.rootExpression.fieldNames()
                uniquenessConstraints.append(fieldNames)
            }
            self.uniquenessConstraints = uniquenessConstraints

            // Inheritance (future implementation)
            self.superentity = nil
            self.superentityName = nil
            self.subentities = []
        }

        // MARK: - CustomDebugStringConvertible

        public var debugDescription: String {
            return "Schema.Entity(name: \(name), indices: \(indices.count))"
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

        // SchemaProperty conformance
        public var propertyName: String { name }

        internal init(
            name: String,
            isOptional: Bool,
            isPrimaryKey: Bool
        ) {
            self.name = name
            self.isOptional = isOptional
            self.isPrimaryKey = isPrimaryKey
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
    func fieldNames() -> [String] {
        if let field = self as? FieldKeyExpression {
            return [field.fieldName]
        } else if let concat = self as? ConcatenateKeyExpression {
            return concat.children.flatMap { $0.fieldNames() }
        }
        // For other expression types, return empty array
        return []
    }
}
