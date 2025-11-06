import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the #Subspace macro
///
/// This freestanding declaration macro is a marker for the @Recordable macro.
/// The @Recordable macro directly reads the #Subspace macro call and its arguments
/// to generate appropriate store() methods.
///
/// **Important Constraint**: Placeholder names in the path template must exactly match
/// the field names in the struct. For example:
/// - Template: `"accounts/{accountID}/users"` → Field must be named `accountID`
/// - Template: `"posts/{postID}/comments"` → Field must be named `postID`
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     #Subspace<User>("accounts/{accountID}/users")
///
///     @PrimaryKey var userID: Int64
///     var accountID: String  // ← Must match placeholder name
///     var email: String
/// }
/// ```
///
/// The @Recordable macro will generate:
/// ```swift
/// extension User {
///     static func store(in container: RecordContainer, path: String) -> RecordStore<User>
///     static func store(in container: RecordContainer, accountID: String) -> RecordStore<User>
/// }
/// ```
public struct SubspaceMacro: DeclarationMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Validate the macro usage
        // Ensure a generic type parameter is provided
        guard let genericClause = node.genericArgumentClause,
              genericClause.arguments.first != nil else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#Subspace requires a type parameter (e.g., #Subspace<User>)")
                )
            ])
        }

        // Extract the path template argument
        guard let pathTemplateArg = node.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#Subspace requires a path template string argument")
                )
            ])
        }

        // Validate that the path template is a string literal
        guard let stringLiteral = pathTemplateArg.expression.as(StringLiteralExprSyntax.self),
              stringLiteral.segments.first?.as(StringSegmentSyntax.self) != nil else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(pathTemplateArg.expression),
                    message: MacroExpansionErrorMessage("Path template must be a string literal")
                )
            ])
        }

        // This macro does not generate any declarations.
        // The @Recordable macro reads the #Subspace call directly from the AST.
        return []
    }
}
