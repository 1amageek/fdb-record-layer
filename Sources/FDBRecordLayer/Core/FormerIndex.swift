import Foundation

/// Represents a formerly used index that has been removed from the schema
///
/// FormerIndex is used to track indexes that have been removed during schema evolution.
/// This prevents index names from being reused in incompatible ways and maintains
/// a history of schema changes.
///
/// **Purpose**:
/// - Track removed indexes for schema evolution validation
/// - Prevent name reuse conflicts
/// - Maintain schema change history
/// - Enable safe rollback scenarios
///
/// **Usage**:
/// ```swift
/// // When removing an index from metadata:
/// let formerIndex = FormerIndex(
///     name: "old_email_index",
///     addedVersion: 1,
///     removedVersion: 5,
///     formerName: "user_by_email"  // optional, if renamed before removal
/// )
///
/// // Add to metadata:
/// try metaData.addFormerIndex(formerIndex)
/// ```
///
/// **Relationship with MetaDataEvolutionValidator**:
/// The validator uses FormerIndex to:
/// 1. Detect if a new index reuses a former index name
/// 2. Verify that removed indexes are replaced with FormerIndex entries
/// 3. Prevent incompatible schema changes
public struct FormerIndex: Sendable, Hashable, Codable {
    // MARK: - Properties

    /// The name of the former index
    ///
    /// This is the primary identifier for the index.
    /// Once an index name becomes a FormerIndex, it should not be reused
    /// for a new index with different characteristics.
    public let name: String

    /// Schema version when the index was originally added
    ///
    /// This helps track the lifecycle of the index.
    public let addedVersion: Int

    /// Schema version when the index was removed
    ///
    /// This marks when the index transitioned to FormerIndex status.
    public let removedVersion: Int

    /// Optional former name of this index
    ///
    /// If the index was renamed before removal, this field stores its previous name.
    /// This creates a chain of former names for tracking index evolution.
    ///
    /// Example:
    /// ```
    /// Version 1: Index "email_idx" created
    /// Version 3: Renamed to "user_by_email"
    /// Version 5: Removed
    /// FormerIndex(name: "user_by_email", formerName: "email_idx", ...)
    /// ```
    public let formerName: String?

    /// Optional subspace tuple key that was used by this index
    ///
    /// This is stored for reference and to detect potential conflicts
    /// if a new index tries to use the same subspace.
    public let subspaceTupleKey: (any TupleElement)?

    // MARK: - Initialization

    /// Initialize a FormerIndex
    ///
    /// - Parameters:
    ///   - name: The name of the former index
    ///   - addedVersion: Schema version when originally added
    ///   - removedVersion: Schema version when removed
    ///   - formerName: Optional previous name if the index was renamed
    ///   - subspaceTupleKey: Optional subspace key that was used
    public init(
        name: String,
        addedVersion: Int,
        removedVersion: Int,
        formerName: String? = nil,
        subspaceTupleKey: (any TupleElement)? = nil
    ) {
        // Validate version progression
        precondition(
            removedVersion >= addedVersion,
            "FormerIndex '\(name)': removedVersion (\(removedVersion)) must be >= addedVersion (\(addedVersion))"
        )

        self.name = name
        self.addedVersion = addedVersion
        self.removedVersion = removedVersion
        self.formerName = formerName
        self.subspaceTupleKey = subspaceTupleKey
    }

    /// Create a FormerIndex from an existing Index being removed
    ///
    /// This is a convenience initializer for when removing an index from metadata.
    ///
    /// - Parameters:
    ///   - index: The index being removed
    ///   - addedVersion: The schema version at which the index was originally added
    ///   - removedVersion: The schema version at which it's being removed
    /// - Returns: A FormerIndex representing the removed index
    public static func from(
        index: Index,
        addedVersion: Int,
        removedVersion: Int
    ) -> FormerIndex {
        return FormerIndex(
            name: index.name,
            addedVersion: addedVersion,
            removedVersion: removedVersion,
            formerName: nil,
            subspaceTupleKey: index.subspaceTupleKey
        )
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(addedVersion)
        hasher.combine(removedVersion)
        hasher.combine(formerName)
    }

    public static func == (lhs: FormerIndex, rhs: FormerIndex) -> Bool {
        return lhs.name == rhs.name &&
               lhs.addedVersion == rhs.addedVersion &&
               lhs.removedVersion == rhs.removedVersion &&
               lhs.formerName == rhs.formerName
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case name
        case addedVersion
        case removedVersion
        case formerName
        case subspaceTupleKey
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(addedVersion, forKey: .addedVersion)
        try container.encode(removedVersion, forKey: .removedVersion)
        try container.encodeIfPresent(formerName, forKey: .formerName)

        // Note: subspaceTupleKey is not encoded as it may not be Codable
        // This can be extended if needed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        addedVersion = try container.decode(Int.self, forKey: .addedVersion)
        removedVersion = try container.decode(Int.self, forKey: .removedVersion)
        formerName = try container.decodeIfPresent(String.self, forKey: .formerName)
        subspaceTupleKey = nil  // Not decoded
    }
}

// MARK: - CustomStringConvertible

extension FormerIndex: CustomStringConvertible {
    public var description: String {
        var parts = [
            "FormerIndex(name: \"\(name)\"",
            "added: v\(addedVersion)",
            "removed: v\(removedVersion)"
        ]

        if let formerName = formerName {
            parts.append("formerName: \"\(formerName)\"")
        }

        return parts.joined(separator: ", ") + ")"
    }
}
