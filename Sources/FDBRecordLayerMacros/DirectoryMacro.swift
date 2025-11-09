import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the #Directory macro
///
/// This freestanding declaration macro validates the directory path syntax and layer parameter,
/// serving as a marker for the @Recordable macro. The @Recordable macro reads the #Directory
/// call from the AST to generate type-safe store() methods.
///
/// **Path Elements**: The path is an array where each element can be:
/// - String literal: `"app"`, `"tenants"`, `"users"` (static path segments)
/// - KeyPath expression: `\.accountID`, `\.channelID` (dynamic partition keys)
///
/// **Layer**: The layer parameter specifies the directory type:
/// - `.recordStore` (default): Standard RecordStore directory
/// - `.partition`: Multi-tenant partition (requires at least one KeyPath in path)
/// - `.luceneIndex`, `.timeSeries`, `.vectorIndex`: Special storage types
/// - Custom: `"my_custom_format_v2"`
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     #Directory<User>(["app", "users"], layer: .recordStore)
///
///     @PrimaryKey var userID: Int64
///     var email: String
/// }
/// ```
///
/// **Multi-tenant with Partition**:
/// ```swift
/// @Recordable
/// struct Order {
///     #Directory<Order>(
///         ["tenants", \.accountID, "orders"],
///         layer: .partition
///     )
///
///     @PrimaryKey var orderID: Int64
///     var accountID: String  // Corresponds to \.accountID KeyPath
/// }
/// ```
///
/// **Multi-level partitioning**:
/// ```swift
/// @Recordable
/// struct Message {
///     #Directory<Message>(
///         ["tenants", \.accountID, "channels", \.channelID, "messages"],
///         layer: .partition
///     )
///
///     @PrimaryKey var messageID: Int64
///     var accountID: String  // First partition key
///     var channelID: String  // Second partition key
/// }
/// ```
///
/// **Generated code** (by @Recordable macro):
/// ```swift
/// // Basic directory
/// extension User {
///     static func openDirectory(database: any DatabaseProtocol) async throws -> DirectorySubspace
///     static func store(database: any DatabaseProtocol, metaData: RecordMetaData) async throws -> RecordStore<User>
/// }
///
/// // Partition directory
/// extension Order {
///     static func openDirectory(accountID: String, database: any DatabaseProtocol) async throws -> DirectorySubspace
///     static func store(accountID: String, database: any DatabaseProtocol, metaData: RecordMetaData) async throws -> RecordStore<Order>
/// }
/// ```
///
/// **Validation**:
/// - Generic type parameter `<T>` is required
/// - Path must be an array literal
/// - Array elements must be string literals or KeyPath expressions
/// - KeyPath fields must exist in the struct and match the generic type parameter
/// - If `layer: .partition`, at least one KeyPath is required in the path
public struct DirectoryMacro: DeclarationMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Validate the macro usage
        // Ensure a generic type parameter is provided
        guard let genericClause = node.genericArgumentClause,
              let genericArg = genericClause.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#Directory requires a type parameter (e.g., #Directory<User>)")
                )
            ])
        }

        let typeName = genericArg.argument.description.trimmingCharacters(in: .whitespaces)

        // Extract the path array argument (first argument)
        guard let pathArg = node.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#Directory requires a path array argument")
                )
            ])
        }

        // Validate that the path is an array expression
        guard let arrayExpr = pathArg.expression.as(ArrayExprSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(pathArg.expression),
                    message: MacroExpansionErrorMessage("Path must be an array literal (e.g., [\"app\", \"users\", \\.accountID])")
                )
            ])
        }

        // Extract KeyPath fields from the path
        var keyPathFields: [String] = []

        // Validate array elements (string literals or KeyPath expressions)
        for element in arrayExpr.elements {
            let expr = element.expression

            // Check if it's a string literal
            if expr.is(StringLiteralExprSyntax.self) {
                continue
            }

            // Check if it's a KeyPath expression (\.propertyName)
            if let keyPathExpr = expr.as(KeyPathExprSyntax.self) {
                // Extract the property name from the KeyPath
                if let component = keyPathExpr.components.first,
                   let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                    let fieldName = property.declName.baseName.text
                    keyPathFields.append(fieldName)
                }
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

        // Extract the layer argument (second argument, optional)
        var layerExpr: ExprSyntax? = nil
        if node.arguments.count >= 2 {
            // Look for "layer:" labeled argument
            for arg in node.arguments {
                if let label = arg.label, label.text == "layer" {
                    layerExpr = arg.expression
                    break
                }
            }
        }

        // Validate layer: .partition requires at least one KeyPath
        if let layerExpr = layerExpr {
            // Check if layer is .partition
            if let memberAccessExpr = layerExpr.as(MemberAccessExprSyntax.self),
               memberAccessExpr.declName.baseName.text == "partition" {
                // Ensure at least one KeyPath exists
                if keyPathFields.isEmpty {
                    throw DiagnosticsError(diagnostics: [
                        Diagnostic(
                            node: Syntax(layerExpr),
                            message: MacroExpansionErrorMessage("layer: .partition requires at least one KeyPath in the path (e.g., [\"tenants\", \\.accountID, \"orders\"])")
                        )
                    ])
                }
            }
        }

        // This macro does not generate any declarations.
        // The @Recordable macro reads the #Directory call directly from the AST.
        return []
    }
}
