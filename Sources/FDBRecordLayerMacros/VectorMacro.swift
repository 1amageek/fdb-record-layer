import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

/// Implementation of the @Vector macro
///
/// This attached property macro generates vector index metadata for HNSW-based similarity search.
/// It validates parameters and marks properties for index generation by @Recordable.
///
/// Usage:
/// ```swift
/// @Recordable
/// struct Product {
///     #PrimaryKey<Product>([\.productID])
///
///     @Vector(dimensions: 768)
///     var embedding: Vector
///
///     var productID: Int64
/// }
/// ```
///
/// **Parameters**:
/// - `dimensions`: Number of vector dimensions (required, range: [1, 10000])
/// - `metric`: Distance metric (default: `.cosine`)
/// - `m`: HNSW M parameter (default: 16, range: [4, 64])
/// - `efConstruction`: Build-time search depth (default: 100, range: [10, 500])
/// - `efSearch`: Query-time search depth (default: 50, range: [10, 500])
///
/// **Note**: @Vector is an attached peer macro that generates no peer declarations.
/// The @Recordable macro detects @Vector attributes and generates IndexDefinitions with type: .vector.
public struct VectorMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // 1. Validate that @Vector is applied to a property
        guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: VectorMacroDiagnostic.notAppliedToProperty
                )
            )
            return []
        }

        // 2. Extract property name
        guard let binding = varDecl.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: varDecl,
                    message: VectorMacroDiagnostic.invalidPropertyDeclaration
                )
            )
            return []
        }

        let propertyName = pattern.identifier.text

        // 3. Validate parameters
        try validateVectorParameters(node: node, propertyName: propertyName, context: context)

        // 4. @attached(peer) returns empty (metadata collected by @Recordable)
        // The @Recordable macro will scan all properties for @Vector attributes
        // and generate IndexDefinitions with type: .vector
        return []
    }

    private static func validateVectorParameters(
        node: AttributeSyntax,
        propertyName: String,
        context: some MacroExpansionContext
    ) throws {
        // Extract arguments from @Vector(dimensions: 768, metric: .cosine, ...)
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: VectorMacroDiagnostic.missingArguments
                )
            )
            return
        }

        // 1. Validate dimensions: parameter (required)
        guard let dimensionsArg = arguments.first(where: { $0.label?.text == "dimensions" }) else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: VectorMacroDiagnostic.missingDimensions(propertyName: propertyName)
                )
            )
            return
        }

        // dimensions: must be an integer literal
        guard let intExpr = dimensionsArg.expression.as(IntegerLiteralExprSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: dimensionsArg,
                    message: VectorMacroDiagnostic.invalidDimensions
                )
            )
            return
        }

        // Validate dimensions value range [1, 10000]
        if let dimensionsValue = Int(intExpr.literal.text) {
            if dimensionsValue < 1 || dimensionsValue > 10000 {
                context.diagnose(
                    Diagnostic(
                        node: dimensionsArg,
                        message: VectorMacroDiagnostic.dimensionsOutOfRange(dimensionsValue)
                    )
                )
                return
            }
        }

        // 2. Validate metric: parameter if present (optional, default: .cosine)
        if let metricArg = arguments.first(where: { $0.label?.text == "metric" }) {
            // metric: must be a member access expression (e.g., .cosine, .l2, .innerProduct)
            guard metricArg.expression.is(MemberAccessExprSyntax.self) else {
                context.diagnose(
                    Diagnostic(
                        node: metricArg,
                        message: VectorMacroDiagnostic.invalidMetric
                    )
                )
                return
            }
        }
    }
}

// MARK: - Diagnostics

enum VectorMacroDiagnostic {
    case notAppliedToProperty
    case invalidPropertyDeclaration
    case missingArguments
    case missingDimensions(propertyName: String)
    case invalidDimensions
    case dimensionsOutOfRange(Int)
    case invalidMetric
}

extension VectorMacroDiagnostic: DiagnosticMessage {
    var message: String {
        switch self {
        case .notAppliedToProperty:
            return """
            @Vector can only be applied to properties
            Usage: @Vector(dimensions: 768) var embedding: Vector
            """

        case .invalidPropertyDeclaration:
            return """
            @Vector requires a valid property declaration
            Usage: @Vector(dimensions: 768) var embedding: Vector
            """

        case .missingArguments:
            return """
            @Vector requires 'dimensions:' parameter
            Usage: @Vector(dimensions: 768) var embedding: Vector
            """

        case .missingDimensions(let propertyName):
            return """
            @Vector on property '\(propertyName)' requires 'dimensions:' parameter

            Usage: @Vector(dimensions: 768) var \(propertyName): Vector

            Common dimensions:
            - 384: all-MiniLM-L6-v2
            - 512: CLIP ViT-B/32
            - 768: BERT, Sentence-BERT
            - 1536: OpenAI text-embedding-ada-002
            """

        case .invalidDimensions:
            return """
            'dimensions:' parameter must be an integer literal
            Usage: @Vector(dimensions: 768) var embedding: Vector
            """

        case .dimensionsOutOfRange(let value):
            return """
            'dimensions:' must be in range [1, 10000], got \(value)

            Typical ranges:
            - Small (32-128): Fast search, lower accuracy
            - Medium (256-512): Balanced performance
            - Large (768-1536): High accuracy, ML models
            - Very Large (2048-4096): Specialized models
            """

        case .invalidMetric:
            return """
            'metric:' parameter must be a VectorMetric enum value
            Usage: @Vector(dimensions: 768, metric: .cosine) var embedding: Vector

            Valid metrics:
            - .cosine (default): Cosine similarity (99% of ML use cases)
            - .l2: Euclidean distance (normalized vectors)
            - .innerProduct: Dot product (recommendation systems)

            Note: HNSW parameters (m, efConstruction, efSearch) are determined by the index implementation
            """
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "FDBRecordLayerMacros", id: "VectorMacro")
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
