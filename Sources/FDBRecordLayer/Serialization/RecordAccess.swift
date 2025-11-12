import Foundation
import FoundationDB

/// Protocol for accessing record metadata and fields
///
/// RecordAccess provides a unified interface for extracting metadata
/// and field values from records, regardless of their underlying representation
/// (Protobuf messages, dictionaries, etc.).
///
/// **Responsibilities:**
/// - Extract record type name
/// - Evaluate KeyExpressions to get field values
/// - Serialize and deserialize records
///
/// **Consistency:**
/// RecordAccess implementations must be consistent with RecordMetadata.
/// This is verified at RecordStore initialization time.
///
/// **Implementation:**
/// - For typed records: Use GenericRecordAccess<T: Recordable> (recommended)
/// - For custom serialization: Implement RecordAccess protocol directly
public protocol RecordAccess<Record>: Sendable {
    associatedtype Record: Sendable

    // MARK: - Metadata

    /// Get the record type name
    ///
    /// The type name must match one of the record types defined in RecordMetadata.
    ///
    /// - Parameter record: The record to get the type name from
    /// - Returns: Record type name (e.g., "User", "Order")
    func recordName(for record: Record) -> String

    // MARK: - KeyExpression Evaluation

    /// Evaluate a KeyExpression to extract field values
    ///
    /// This method uses the Visitor pattern to traverse the KeyExpression tree
    /// and extract the corresponding values from the record.
    ///
    /// - Parameters:
    ///   - record: The record to evaluate
    ///   - expression: The KeyExpression to evaluate
    /// - Returns: Array of tuple elements representing the extracted values
    /// - Throws: RecordLayerError if field access fails
    func evaluate(
        record: Record,
        expression: KeyExpression
    ) throws -> [any TupleElement]

    /// Extract a single field value
    ///
    /// This method is called by RecordAccessEvaluator during KeyExpression traversal.
    /// Concrete implementations must provide field access logic.
    ///
    /// - Parameters:
    ///   - record: The record to extract from
    ///   - fieldName: The field name (supports dot notation: "user.address.city")
    /// - Returns: Array of tuple elements (typically single element)
    /// - Throws: RecordLayerError if field not found or type conversion fails
    func extractField(
        from record: Record,
        fieldName: String
    ) throws -> [any TupleElement]

    // MARK: - Serialization

    /// Serialize a record to bytes
    ///
    /// - Parameter record: The record to serialize
    /// - Returns: Serialized bytes
    /// - Throws: RecordLayerError.serializationFailed if serialization fails
    func serialize(_ record: Record) throws -> FDB.Bytes

    /// Deserialize bytes to a record
    ///
    /// - Parameter bytes: The bytes to deserialize
    /// - Returns: Deserialized record
    /// - Throws: RecordLayerError.deserializationFailed if deserialization fails
    func deserialize(_ bytes: FDB.Bytes) throws -> Record

    // MARK: - Covering Index Support

    /// Check if this RecordAccess supports reconstruction from covering indexes
    ///
    /// This allows the query planner to skip covering index plans
    /// for types that don't implement reconstruction.
    ///
    /// **Default**: false (safe, conservative)
    ///
    /// **Override**: Return true if reconstruct() is implemented
    var supportsReconstruction: Bool { get }

    /// Reconstruct a record from covering index key and value
    ///
    /// This method enables covering index optimization by reconstructing
    /// records directly from index data without fetching from storage.
    ///
    /// - Parameters:
    ///   - indexKey: The index key (unpacked tuple)
    ///   - indexValue: The index value (packed covering fields)
    ///   - index: The index definition
    ///   - primaryKeyExpression: Primary key expression for field extraction
    /// - Returns: Reconstructed record
    /// - Throws: RecordLayerError.reconstructionNotImplemented or .reconstructionFailed
    func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Record
}

// MARK: - Default Implementation

extension RecordAccess {
    /// Evaluate a KeyExpression (default implementation using Visitor pattern)
    ///
    /// This default implementation creates a RecordAccessEvaluator and uses it
    /// to traverse the KeyExpression tree.
    ///
    /// - Parameters:
    ///   - record: The record to evaluate
    ///   - expression: The KeyExpression to evaluate
    /// - Returns: Array of tuple elements
    /// - Throws: RecordLayerError if evaluation fails
    public func evaluate(
        record: Record,
        expression: KeyExpression
    ) throws -> [any TupleElement] {
        let visitor = RecordAccessEvaluator(recordAccess: self, record: record)
        return try expression.accept(visitor: visitor)
    }

    /// Extract primary key from a record using the primary key expression
    ///
    /// - Parameters:
    ///   - record: The record to extract from
    ///   - primaryKeyExpression: The KeyExpression defining the primary key
    /// - Returns: Tuple representing the primary key
    /// - Throws: RecordLayerError if extraction fails
    public func extractPrimaryKey(
        from record: Record,
        using primaryKeyExpression: KeyExpression
    ) throws -> Tuple {
        let elements = try evaluate(record: record, expression: primaryKeyExpression)
        return TupleHelpers.toTuple(elements)
    }

    /// Reconstruct a record from index key and value
    ///
    /// This method is used by covering indexes to reconstruct records without
    /// fetching from storage.
    ///
    /// **Field Assembly Strategy**:
    /// 1. Extract indexed fields from index key (via rootExpression)
    /// 2. Extract covering fields from index value (via coveringFields)
    /// 3. Extract primary key from index key (last N elements)
    /// 4. Reconstruct record with all available fields
    ///
    /// **Index Key Structure**: `<indexSubspace><rootExpression fields><primaryKey fields>`
    ///
    /// **Implementation Requirements**:
    /// - For @Recordable types: Auto-generated via macro (recommended)
    /// - For hand-written types: Must implement manually
    /// - For legacy code: Fallback to record fetch (safe default)
    ///
    /// **Compatibility**:
    /// This method has a default implementation that throws .reconstructionNotImplemented.
    /// This ensures:
    /// - Compile-time: No errors for existing RecordAccess implementations
    /// - Runtime: Clear error message if covering index is used without implementation
    /// - Migration: Gradual adoption possible
    ///
    /// **Manual Implementation Example**:
    /// ```swift
    /// struct User {
    ///     let userID: Int64
    ///     let name: String
    ///     let email: String
    ///     let city: String
    /// }
    ///
    /// // Index: on city, covering [name, email]
    /// // Key structure: <city><userID>
    /// // Value structure: Tuple(name, email)
    ///
    /// func reconstruct(
    ///     indexKey: Tuple,
    ///     indexValue: FDB.Bytes,
    ///     index: Index,
    ///     primaryKeyExpression: KeyExpression
    /// ) throws -> User {
    ///     // 1. Determine field counts
    ///     let rootCount = index.rootExpression.columnCount  // 1 (city)
    ///     let pkCount = primaryKeyExpression.columnCount    // 1 (userID)
    ///
    ///     // 2. Extract indexed fields from index key
    ///     guard let city = indexKey[0] as? String else {
    ///         throw RecordLayerError.reconstructionFailed(
    ///             recordType: "User",
    ///             reason: "Invalid city field in index key"
    ///         )
    ///     }
    ///
    ///     // 3. Extract primary key from index key (last N elements)
    ///     guard let userID = indexKey[rootCount] as? Int64 else {
    ///         throw RecordLayerError.reconstructionFailed(
    ///             recordType: "User",
    ///             reason: "Invalid userID field in index key"
    ///         )
    ///     }
    ///
    ///     // 4. Extract covering fields from index value
    ///     let coveringTuple = try Tuple.unpack(from: indexValue)
    ///     guard let name = coveringTuple[0] as? String,
    ///           let email = coveringTuple[1] as? String else {
    ///         throw RecordLayerError.reconstructionFailed(
    ///             recordType: "User",
    ///             reason: "Invalid covering fields in index value"
    ///         )
    ///     }
    ///
    ///     // 5. Reconstruct record
    ///     return User(userID: userID, name: name, email: email, city: city)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - indexKey: The index key (unpacked tuple)
    ///   - indexValue: The index value (packed covering fields)
    ///   - index: The index definition
    ///   - primaryKeyExpression: Primary key expression for field extraction
    /// - Returns: Reconstructed record
    /// - Throws: RecordLayerError.reconstructionNotImplemented or .reconstructionFailed
    public func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Record {
        // DEFAULT IMPLEMENTATION: Throw not implemented error
        //
        // This is intentionally not a fatalError() to allow gradual migration:
        // 1. Old code without reconstruct() → Runtime error with clear message
        // 2. New code with @Recordable → Auto-generated implementation
        // 3. Hand-written code → Manual implementation
        //
        // The error includes actionable guidance for users
        throw RecordLayerError.reconstructionNotImplemented(
            recordType: String(describing: Record.self),
            suggestion: """
            To use covering indexes with this record type, either:
            1. Use @Recordable macro (auto-generates reconstruct method)
            2. Manually implement RecordAccess.reconstruct()
            3. Avoid covering indexes for this type (use regular indexes)
            """
        )
    }

    /// Check if this RecordAccess supports reconstruction
    ///
    /// This allows the query planner to skip covering index plans
    /// for types that don't implement reconstruction.
    ///
    /// **Default**: false (safe, conservative)
    ///
    /// **Override**: Return true if reconstruct() is implemented
    ///
    /// - Returns: true if reconstruct() is supported
    public var supportsReconstruction: Bool {
        return false
    }
}

// MARK: - RecordAccessEvaluator

/// Visitor that evaluates KeyExpressions using RecordAccess
///
/// This visitor traverses a KeyExpression tree and extracts values from a record
/// using the provided RecordAccess implementation.
fileprivate struct RecordAccessEvaluator<Access: RecordAccess>: KeyExpressionVisitor {
    let recordAccess: Access
    let record: Access.Record

    typealias Result = [any TupleElement]

    func visitField(_ fieldName: String) throws -> [any TupleElement] {
        return try recordAccess.extractField(from: record, fieldName: fieldName)
    }

    func visitConcatenate(_ expressions: [KeyExpression]) throws -> [any TupleElement] {
        var result: [any TupleElement] = []
        for expression in expressions {
            let values = try expression.accept(visitor: self)
            result.append(contentsOf: values)
        }
        return result
    }

    func visitLiteral(_ value: any TupleElement) throws -> [any TupleElement] {
        return [value]
    }

    func visitEmpty() throws -> [any TupleElement] {
        return []
    }

    func visitNest(_ parentField: String, _ child: KeyExpression) throws -> [any TupleElement] {
        // Evaluate nested field expressions by combining parent field with child expression
        //
        // Strategy: We leverage RecordAccess.extractField's dot-notation support
        // for simple cases, and recursively handle complex nested expressions.

        // Case 1: child is a FieldKeyExpression
        // Convert NestExpression("user", FieldKeyExpression("name")) to "user.name"
        if let fieldExpr = child as? FieldKeyExpression {
            let nestedPath = "\(parentField).\(fieldExpr.fieldName)"
            return try recordAccess.extractField(from: record, fieldName: nestedPath)
        }

        // Case 2: child is a ConcatenateKeyExpression
        // NestExpression("user", ConcatenateKeyExpression([field1, field2]))
        // becomes [user.field1, user.field2]
        if let concatExpr = child as? ConcatenateKeyExpression {
            var results: [any TupleElement] = []
            for expr in concatExpr.children {
                // Recursively nest each child
                let nestedExpr = NestExpression(parentField: parentField, child: expr)
                let values = try nestedExpr.accept(visitor: self)
                results.append(contentsOf: values)
            }
            return results
        }

        // Case 3: child is EmptyKeyExpression
        // Empty is independent of nesting - return empty array
        if child is EmptyKeyExpression {
            return []
        }

        // Case 4: child is another NestExpression
        // NestExpression("user", NestExpression("address", FieldKeyExpression("city")))
        // becomes "user.address.city"
        if let nestedNest = child as? NestExpression {
            // Combine parent fields with dot notation
            let combinedPath = "\(parentField).\(nestedNest.parentField)"
            let combinedExpr = NestExpression(parentField: combinedPath, child: nestedNest.child)
            return try combinedExpr.accept(visitor: self)
        }

        // Case 5: For other expression types (e.g., Literal), just evaluate them
        // Literals and other simple expressions are independent of nesting
        // We recursively call accept() which will invoke the appropriate visitor method
        return try child.accept(visitor: self)
    }
}
