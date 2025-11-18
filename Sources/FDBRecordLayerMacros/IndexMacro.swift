import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

/// Implementation of the #Index macro
///
/// This freestanding macro generates index metadata declarations.
/// It analyzes the provided KeyPaths and creates corresponding index definitions
/// that can be registered with the RecordMetaData.
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     #Index<User>([\.email])
///     #Index<User>([\.country, \.city], name: "location_index")
///     #PrimaryKey<User>([\.userID])
///
///     var userID: Int64
///     var email: String
///     var country: String
///     var city: String
/// }
/// ```
///
/// **Note**: #Index is a marker macro that generates no code itself.
/// The @Recordable macro detects #Index calls and generates IndexDefinitions in the extension.
/// This approach avoids circular reference errors while using KeyPaths.
public struct IndexMacro: DeclarationMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // #Index is a marker macro - it generates no code
        // The @Recordable macro will detect the UNEXPANDED macro call (MacroExpansionDeclSyntax)
        // and extract the KeyPath information directly from it
        //
        // This works because:
        // - @Recordable's expansion() receives the ORIGINAL syntax tree before other macros expand
        // - It can see MacroExpansionDeclSyntax nodes for #Index/#Unique
        // - It extracts arguments and generates IndexDefinition properties in the extension

        // Validate syntax before returning empty array
        try validateIndexSyntax(node: node, context: context)

        return []
    }

    private static func validateIndexSyntax(
        node: some FreestandingMacroExpansionSyntax,
        context: some MacroExpansionContext
    ) throws {
        // 1. Validate generic type argument exists
        guard let genericArguments = node.genericArgumentClause?.arguments,
              !genericArguments.isEmpty else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: IndexMacroDiagnostic.missingGenericType
                )
            )
            return
        }

        // 2. Validate first argument is present (KeyPath array)
        guard let firstArg = node.arguments.first else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: IndexMacroDiagnostic.missingKeyPathArray
                )
            )
            return
        }

        // 3. Validate first argument is an array literal
        guard let arrayExpr = firstArg.expression.as(ArrayExprSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: firstArg,
                    message: IndexMacroDiagnostic.invalidKeyPathArray
                )
            )
            return
        }

        // 4. Validate array is not empty
        if arrayExpr.elements.isEmpty {
            context.diagnose(
                Diagnostic(
                    node: arrayExpr,
                    message: IndexMacroDiagnostic.emptyKeyPathArray
                )
            )
            return
        }

        // 5. Validate that all array elements are KeyPath expressions
        for element in arrayExpr.elements {
            // Check if the element is a KeyPath expression
            guard element.expression.is(KeyPathExprSyntax.self) else {
                context.diagnose(
                    Diagnostic(
                        node: element,
                        message: IndexMacroDiagnostic.nonKeyPathElement
                    )
                )
                return
            }
        }

        // 6. Validate name: parameter if present
        if let nameArg = node.arguments.first(where: { $0.label?.text == "name" }) {
            // name: must be a string literal
            guard nameArg.expression.is(StringLiteralExprSyntax.self) else {
                context.diagnose(
                    Diagnostic(
                        node: nameArg,
                        message: IndexMacroDiagnostic.invalidNameParameter
                    )
                )
                return
            }
        }

        // 7. Validate covering: parameter if present
        if let coveringArg = node.arguments.first(where: { $0.label?.text == "covering" }) {
            // covering: must be an array literal
            guard let coveringArrayExpr = coveringArg.expression.as(ArrayExprSyntax.self) else {
                context.diagnose(
                    Diagnostic(
                        node: coveringArg,
                        message: IndexMacroDiagnostic.invalidCoveringParameter
                    )
                )
                return
            }

            // Validate that all covering elements are KeyPath expressions
            for element in coveringArrayExpr.elements {
                guard element.expression.is(KeyPathExprSyntax.self) else {
                    context.diagnose(
                        Diagnostic(
                            node: element,
                            message: IndexMacroDiagnostic.nonKeyPathCoveringElement
                        )
                    )
                    return
                }
            }
        }
    }
}

// MARK: - Diagnostics

enum IndexMacroDiagnostic {
    case missingGenericType
    case missingKeyPathArray
    case invalidKeyPathArray
    case emptyKeyPathArray
    case nonKeyPathElement
    case invalidNameParameter
    case invalidCoveringParameter
    case nonKeyPathCoveringElement
}

extension IndexMacroDiagnostic: DiagnosticMessage {
    var message: String {
        switch self {
        case .missingGenericType:
            return """
            #Index macro requires a generic type argument
            Usage: #Index<YourType>([\\YourType.field1, \\YourType.field2])
            """

        case .missingKeyPathArray:
            return """
            #Index macro requires a KeyPath array as the first argument
            Usage: #Index<YourType>([\\YourType.field1, \\YourType.field2])
            """

        case .invalidKeyPathArray:
            return """
            First argument must be an array literal of KeyPaths
            Usage: #Index<YourType>([\\YourType.field1, \\YourType.field2])
            """

        case .emptyKeyPathArray:
            return """
            KeyPath array cannot be empty
            Provide at least one field: #Index<YourType>([\\YourType.field1])
            """

        case .nonKeyPathElement:
            return """
            All array elements must be KeyPath expressions
            Invalid: #Index<YourType>(["email"])
            Correct: #Index<YourType>([\\YourType.email])
            """

        case .invalidNameParameter:
            return """
            'name:' parameter must be a string literal
            Usage: #Index<YourType>([\\YourType.field], name: "my_index")
            """

        case .invalidCoveringParameter:
            return """
            'covering:' parameter must be an array literal of KeyPaths
            Usage: #Index<YourType>([\\YourType.city], covering: [\\YourType.name, \\YourType.email])
            """

        case .nonKeyPathCoveringElement:
            return """
            All covering array elements must be KeyPath expressions
            Invalid: #Index<YourType>([\\YourType.city], covering: ["name"])
            Correct: #Index<YourType>([\\YourType.city], covering: [\\YourType.name])
            """
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "FDBRecordLayerMacros", id: "IndexMacro")
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
