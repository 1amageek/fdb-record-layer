import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

/// Implementation of the #Unique macro
///
/// This freestanding macro generates unique index metadata declarations.
/// It analyzes the provided KeyPaths and creates corresponding unique index definitions
/// that can be registered with the RecordMetaData.
///
/// Unique indexes enforce uniqueness constraints on the specified fields.
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     #Unique<User>([\.email])  // Email must be unique
///
///     @PrimaryKey var userID: Int64
///     var email: String
/// }
/// ```
///
/// **Note**: #Unique is a marker macro that generates no code itself.
/// The @Recordable macro detects #Unique calls and generates IndexDefinitions in the extension.
/// This approach avoids circular reference errors while using KeyPaths.
public struct UniqueMacro: DeclarationMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // #Unique is a marker macro - it generates no code
        // The @Recordable macro will detect the UNEXPANDED macro call (MacroExpansionDeclSyntax)
        // and extract the KeyPath information directly from it
        //
        // This works because:
        // - @Recordable's expansion() receives the ORIGINAL syntax tree before other macros expand
        // - It can see MacroExpansionDeclSyntax nodes for #Index/#Unique
        // - It extracts arguments and generates IndexDefinition properties with unique: true in the extension

        // Validate syntax before returning empty array
        try validateUniqueSyntax(node: node, context: context)

        return []
    }

    private static func validateUniqueSyntax(
        node: some FreestandingMacroExpansionSyntax,
        context: some MacroExpansionContext
    ) throws {
        // 1. Validate generic type argument exists
        guard let genericArguments = node.genericArgumentClause?.arguments,
              !genericArguments.isEmpty else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: UniqueMacroDiagnostic.missingGenericType
                )
            )
            return
        }

        // 2. Validate first argument is present (KeyPath array)
        guard let firstArg = node.arguments.first else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: UniqueMacroDiagnostic.missingKeyPathArray
                )
            )
            return
        }

        // 3. Validate first argument is an array literal
        guard let arrayExpr = firstArg.expression.as(ArrayExprSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: firstArg,
                    message: UniqueMacroDiagnostic.invalidKeyPathArray
                )
            )
            return
        }

        // 4. Validate array is not empty
        if arrayExpr.elements.isEmpty {
            context.diagnose(
                Diagnostic(
                    node: arrayExpr,
                    message: UniqueMacroDiagnostic.emptyKeyPathArray
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
                        message: UniqueMacroDiagnostic.nonKeyPathElement
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
                        message: UniqueMacroDiagnostic.invalidNameParameter
                    )
                )
                return
            }
        }
    }
}

// MARK: - Diagnostics

enum UniqueMacroDiagnostic {
    case missingGenericType
    case missingKeyPathArray
    case invalidKeyPathArray
    case emptyKeyPathArray
    case nonKeyPathElement
    case invalidNameParameter
}

extension UniqueMacroDiagnostic: DiagnosticMessage {
    var message: String {
        switch self {
        case .missingGenericType:
            return """
            #Unique macro requires a generic type argument
            Usage: #Unique<YourType>([\\YourType.field1, \\YourType.field2])
            """

        case .missingKeyPathArray:
            return """
            #Unique macro requires a KeyPath array as the first argument
            Usage: #Unique<YourType>([\\YourType.field1, \\YourType.field2])
            """

        case .invalidKeyPathArray:
            return """
            First argument must be an array literal of KeyPaths
            Usage: #Unique<YourType>([\\YourType.field1, \\YourType.field2])
            """

        case .emptyKeyPathArray:
            return """
            KeyPath array cannot be empty
            Provide at least one field: #Unique<YourType>([\\YourType.field1])
            """

        case .nonKeyPathElement:
            return """
            All array elements must be KeyPath expressions
            Invalid: #Unique<YourType>(["email"])
            Correct: #Unique<YourType>([\\YourType.email])
            """

        case .invalidNameParameter:
            return """
            'name:' parameter must be a string literal
            Usage: #Unique<YourType>([\\YourType.field], name: "my_index")
            """
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "FDBRecordLayerMacros", id: "UniqueMacro")
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
