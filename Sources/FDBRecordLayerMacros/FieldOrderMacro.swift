import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the #FieldOrder macro
///
/// This freestanding macro explicitly specifies the order of fields for Protobuf compatibility.
/// By default, fields are numbered in declaration order. Use this macro only when you need
/// to maintain compatibility with existing Protobuf schemas.
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     #FieldOrder<User>([\\.userID, \\.email, \\.name, \\.age])
///
///     @PrimaryKey var userID: Int64  // field_number = 1
///     var email: String               // field_number = 2
///     var name: String                // field_number = 3
///     var age: Int                    // field_number = 4
/// }
/// ```
///
/// Note: This macro generates metadata that the @Recordable macro can read
/// to override the default field numbering.
public struct FieldOrderMacro: DeclarationMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Extract the generic type parameter
        guard let genericClause = node.genericArgumentClause,
              let typeArg = genericClause.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#FieldOrder requires a type parameter (e.g., #FieldOrder<User>)")
                )
            ])
        }

        _ = typeArg.argument.description.trimmingCharacters(in: .whitespaces)

        // Extract arguments - node.arguments is already LabeledExprListSyntax
        let arguments = node.arguments

        // Find the keyPaths argument
        guard let keyPathsArg = arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#FieldOrder requires a keyPaths array argument")
                )
            ])
        }

        // Extract the key paths from the array
        let keyPaths = try extractKeyPaths(from: keyPathsArg.expression)

        // Generate field order mapping
        let fieldOrderMapping = keyPaths.enumerated().map { index, fieldName in
            "\"\(fieldName)\": \(index + 1)"
        }.joined(separator: ", ")

        // Generate the field order metadata declaration
        let fieldOrderDecl: DeclSyntax = """
        static let _fieldOrder: [String: Int] = [\(raw: fieldOrderMapping)]
        """

        return [fieldOrderDecl]
    }

    private static func extractKeyPaths(from expression: ExprSyntax) throws -> [String] {
        guard let arrayExpr = expression.as(ArrayExprSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(expression),
                    message: MacroExpansionErrorMessage("keyPaths must be an array literal")
                )
            ])
        }

        var keyPaths: [String] = []
        for element in arrayExpr.elements {
            if let keyPathExpr = element.expression.as(KeyPathExprSyntax.self) {
                // Extract the property name from the key path
                if let component = keyPathExpr.components.last,
                   let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                    keyPaths.append(property.declName.baseName.text)
                }
            }
        }

        return keyPaths
    }
}
