import Foundation

/// Visitor pattern for traversing and evaluating KeyExpressions
///
/// KeyExpressionVisitor provides a unified way to traverse and process
/// KeyExpression trees without depending on the concrete types.
///
/// **Usage:**
/// ```swift
/// struct MyVisitor: KeyExpressionVisitor {
///     typealias Result = [String]
///
///     func visitField(_ fieldName: String) throws -> [String] {
///         return [fieldName]
///     }
///
///     func visitConcatenate(_ expressions: [KeyExpression]) throws -> [String] {
///         var result: [String] = []
///         for expression in expressions {
///             result.append(contentsOf: try expression.accept(visitor: self))
///         }
///         return result
///     }
///
///     // ... implement other methods
/// }
/// ```
public protocol KeyExpressionVisitor {
    associatedtype Result

    /// Visit a field expression
    /// - Parameter fieldName: The field name to extract
    /// - Returns: The result of visiting this field
    /// - Throws: If field access fails
    func visitField(_ fieldName: String) throws -> Result

    /// Visit a concatenation of multiple expressions
    /// - Parameter expressions: The child expressions to concatenate
    /// - Returns: The result of visiting the concatenation
    /// - Throws: If any child expression fails
    func visitConcatenate(_ expressions: [KeyExpression]) throws -> Result

    /// Visit a literal expression
    /// - Parameter value: The literal value
    /// - Returns: The result of visiting the literal
    /// - Throws: If literal processing fails
    func visitLiteral(_ value: any TupleElement) throws -> Result

    /// Visit an empty expression
    /// - Returns: The result of visiting the empty expression
    /// - Throws: If empty processing fails
    func visitEmpty() throws -> Result

    /// Visit a nest expression
    /// - Parameters:
    ///   - parentField: The parent field name
    ///   - child: The child expression to evaluate on the nested record
    /// - Returns: The result of visiting the nest expression
    /// - Throws: If nest processing fails
    func visitNest(_ parentField: String, _ child: KeyExpression) throws -> Result

    /// Visit a range boundary expression
    /// - Parameters:
    ///   - fieldName: The field name containing the Range type
    ///   - component: The boundary component to extract (lowerBound/upperBound)
    /// - Returns: The result of visiting the range boundary
    /// - Throws: If range boundary extraction fails
    func visitRangeBoundary(_ fieldName: String, _ component: RangeComponent) throws -> Result
}

// MARK: - Default Implementation

extension KeyExpressionVisitor {
    /// Default implementation of visitRangeBoundary that throws an error
    ///
    /// Visitors that need to support RangeKeyExpression must override this method.
    /// The default implementation throws an unsupported error to maintain backward compatibility.
    public func visitRangeBoundary(_ fieldName: String, _ component: RangeComponent) throws -> Result {
        throw RecordLayerError.internalError(
            "RangeKeyExpression not supported by this visitor. Override visitRangeBoundary() to support Range indexes."
        )
    }
}

// MARK: - KeyExpression Visitor Support

extension KeyExpression {
    /// Accept a visitor to traverse this expression
    ///
    /// This method implements the Visitor pattern, allowing external code
    /// to process KeyExpression trees without depending on concrete types.
    ///
    /// - Parameter visitor: The visitor to accept
    /// - Returns: The result of the visitor's traversal
    /// - Throws: If the visitor encounters an error or unsupported expression type
    public func accept<V: KeyExpressionVisitor>(visitor: V) throws -> V.Result {
        switch self {
        case let field as FieldKeyExpression:
            return try visitor.visitField(field.fieldName)

        case let concat as ConcatenateKeyExpression:
            return try visitor.visitConcatenate(concat.children)

        case is EmptyKeyExpression:
            return try visitor.visitEmpty()

        case let nest as NestExpression:
            return try visitor.visitNest(nest.parentField, nest.child)

        case let rangeExpr as RangeKeyExpression:
            return try visitor.visitRangeBoundary(rangeExpr.fieldName, rangeExpr.component)

        default:
            // Handle all LiteralKeyExpression types generically
            // We need to use reflection to extract the value since we can't
            // pattern match on generic types directly
            if let literalBase = self as? any LiteralKeyExpressionBase {
                return try visitor.visitLiteral(literalBase.anyValue)
            }

            throw RecordLayerError.internalError("Unsupported KeyExpression type: \(type(of: self))")
        }
    }
}

// MARK: - LiteralKeyExpression Base Protocol

/// Internal protocol to enable type-erased access to LiteralKeyExpression values
fileprivate protocol LiteralKeyExpressionBase {
    var anyValue: any TupleElement { get }
}

extension LiteralKeyExpression: LiteralKeyExpressionBase {
    fileprivate var anyValue: any TupleElement {
        return value
    }
}
