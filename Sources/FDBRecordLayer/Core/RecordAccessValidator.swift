import Foundation

/// Validates consistency between RecordAccess and RecordMetadata
///
/// RecordAccessValidator performs static validation at RecordStore initialization
/// to ensure that the RecordAccess implementation is consistent with the
/// RecordMetadata definitions.
///
/// **Validation Checks:**
/// 1. Primary key expressions are structurally valid
/// 2. Index key expressions are structurally valid
/// 3. Field names are non-empty and properly formatted
///
/// **Limitations:**
/// Full validation requires actual record instances, which are not available
/// at initialization time. Runtime validation is performed in RecordStore operations.
///
/// **Usage:**
/// ```swift
/// let validator = RecordAccessValidator(
///     metaData: metaData,
///     recordAccess: recordAccess
/// )
/// try validator.validate()
/// ```
public struct RecordAccessValidator {
    private let schema: Schema

    /// Initialize validator
    ///
    /// - Parameters:
    ///   - schema: The Schema to validate against
    ///   - recordAccess: The RecordAccess implementation (not used for static validation)
    public init<Access: RecordAccess>(schema: Schema, recordAccess: Access) {
        self.schema = schema
        // Note: recordAccess is not stored because static validation only checks
        // KeyExpression structure, not actual field access
    }

    /// Validate consistency
    ///
    /// Performs static validation of KeyExpressions in Schema.
    ///
    /// - Throws: RecordLayerError if validation fails
    public func validate() throws {
        // 1. Validate primary keys for all entities
        for (_, entity) in schema.entitiesByName {
            // Use canonical primary key expression from entity
            try validateKeyExpression(
                entity.primaryKeyExpression,
                context: "Primary key for \(entity.name)"
            )
        }

        // 2. Validate index keys
        for (_, index) in schema.indexesByName {
            try validateKeyExpression(
                index.rootExpression,
                context: "Index \(index.name)"
            )
        }
    }

    /// Validate a KeyExpression
    ///
    /// - Parameters:
    ///   - expression: The expression to validate
    ///   - context: Description of where this expression is used (for error messages)
    /// - Throws: RecordLayerError if validation fails
    private func validateKeyExpression(
        _ expression: KeyExpression,
        context: String
    ) throws {
        let visitor = ValidationVisitor(context: context)
        try expression.accept(visitor: visitor)
    }
}

// MARK: - ValidationVisitor

/// Visitor that validates KeyExpression structure
private struct ValidationVisitor: KeyExpressionVisitor {
    let context: String

    typealias Result = Void

    func visitField(_ fieldName: String) throws {
        // Validate field name is non-empty
        guard !fieldName.isEmpty else {
            throw RecordLayerError.invalidKey("\(context): Empty field name")
        }

        // Validate field name doesn't contain invalid characters
        // (This is a basic check - more sophisticated validation could be added)
        let invalidChars = CharacterSet.controlCharacters
        if fieldName.rangeOfCharacter(from: invalidChars) != nil {
            throw RecordLayerError.invalidKey("\(context): Field name contains invalid characters: \(fieldName)")
        }
    }

    func visitConcatenate(_ expressions: [KeyExpression]) throws {
        // Validate concatenation has at least one child
        guard !expressions.isEmpty else {
            throw RecordLayerError.invalidKey("\(context): Concatenate expression must have at least one child")
        }

        // Recursively validate all children
        for expression in expressions {
            try expression.accept(visitor: self)
        }
    }

    func visitLiteral(_ value: any TupleElement) throws {
        // Literals are always valid
    }

    func visitEmpty() throws {
        // Empty is always valid
    }

    func visitNest(_ parentField: String, _ child: KeyExpression) throws {
        // Validate parent field name
        try visitField(parentField)

        // Recursively validate child expression
        try child.accept(visitor: self)
    }
}
