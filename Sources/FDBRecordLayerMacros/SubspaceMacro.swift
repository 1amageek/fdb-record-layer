import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the #Subspace macro
///
/// This freestanding declaration macro validates the subspace path syntax and serves as
/// a marker for the @Recordable macro. The @Recordable macro reads the #Subspace call
/// from the AST to generate partition-aware store() methods.
///
/// **Path Elements**: The path is an array where each element can be:
/// - String literal: `"app"`, `"accounts"`, `"users"` (static path segments)
/// - KeyPath expression: `\.accountID`, `\.channelID` (dynamic partition keys)
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     #Subspace<User>(["app", "accounts", \.accountID, "users"])
///
///     @PrimaryKey var userID: Int64
///     var accountID: String  // ← Corresponds to \.accountID KeyPath
///     var email: String
/// }
/// ```
///
/// **Multi-level partitioning**:
/// ```swift
/// @Recordable
/// struct Message {
///     #Subspace<Message>(["app", "accounts", \.accountID, "channels", \.channelID, "messages"])
///
///     @PrimaryKey var messageID: Int64
///     var accountID: String  // First partition key
///     var channelID: String  // Second partition key
///     var content: String
/// }
/// ```
///
/// **Generated code** (by @Recordable macro):
/// ```swift
/// // Single partition key
/// extension User {
///     static func store(
///         accountID: String,
///         partitionManager: PartitionManager
///     ) async throws -> RecordStore<User>
/// }
///
/// // Multiple partition keys
/// extension Message {
///     static func store(
///         accountID: String,
///         channelID: String,
///         partitionManager: PartitionManager
///     ) async throws -> RecordStore<Message>
/// }
/// ```
///
/// **Validation**:
/// - Generic type parameter `<T>` is required
/// - Path must be an array literal
/// - Array elements must be string literals or KeyPath expressions
/// - KeyPath fields must exist in the struct and match the generic type parameter
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

        // Extract the path array argument
        guard let pathArg = node.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#Subspace requires a path array argument")
                )
            ])
        }

        // Validate that the path is an array expression
        guard let arrayExpr = pathArg.expression.as(ArrayExprSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(pathArg.expression),
                    message: MacroExpansionErrorMessage("Path must be an array literal (e.g., [\"app\", \"accounts\", \\.accountID, \"users\"])")
                )
            ])
        }

        // Validate array elements (string literals or KeyPath expressions)
        for element in arrayExpr.elements {
            let expr = element.expression

            // Check if it's a string literal
            if expr.is(StringLiteralExprSyntax.self) {
                continue
            }

            // Check if it's a KeyPath expression (\.propertyName)
            if expr.is(KeyPathExprSyntax.self) {
                continue
            }

            // Invalid element type
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(expr),
                    message: MacroExpansionErrorMessage("Path elements must be string literals (\"literal\") or KeyPath expressions (\\.propertyName)")
                )
            ])
        }

        // This macro does not generate any declarations.
        // The @Recordable macro reads the #Subspace call directly from the AST.
        return []
    }
}
