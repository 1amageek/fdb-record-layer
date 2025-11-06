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
/// RecordAccess implementations must be consistent with RecordMetaData.
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
    /// The type name must match one of the record types defined in RecordMetaData.
    ///
    /// - Parameter record: The record to get the type name from
    /// - Returns: Record type name (e.g., "User", "Order")
    func recordTypeName(for record: Record) -> String

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
