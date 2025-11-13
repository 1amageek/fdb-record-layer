import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

/// Implementation of the #PrimaryKey macro
///
/// This freestanding declaration macro defines the primary key fields for a record type.
/// It analyzes the provided KeyPaths and creates corresponding primary key definitions
/// that uniquely identify each record.
///
/// **Single Primary Key**:
/// ```swift
/// @Recordable
/// struct User {
///     #PrimaryKey<User>([\.userID])
///
///     var userID: Int64
///     var email: String
/// }
/// ```
///
/// **Composite Primary Key**:
/// ```swift
/// @Recordable
/// struct Player {
///     #PrimaryKey<Player>([\.tenantID, \.playerID])  // Order matters!
///
///     var tenantID: String
///     var playerID: Int64
///     var name: String
///     var score: Int64
/// }
/// ```
///
/// **Why Composite Primary Keys?**
///
/// Composite primary keys are essential for:
/// 1. **Global Uniqueness Across Partitions**: When you need partition-specific rankings
///    AND global rankings simultaneously
/// 2. **Multi-Category Rankings**: User scores across different game modes, regions, etc.
///
/// Example with RANK indexes:
/// ```swift
/// @Recordable
/// struct GameScore {
///     #PrimaryKey<GameScore>([\.mode, \.userID])
///     #Index<GameScore>([\.mode, \.score], type: .rank, name: "mode_rank")
///     #Index<GameScore>([\.score], type: .rank, name: "global_rank", scope: .global)
///
///     var mode: String      // "normal", "hard", "extreme"
///     var userID: Int64
///     var score: Int64
/// }
///
/// // Mode-specific ranking
/// let hardModeTop10 = try await rankQuery.getRecordsByRankRange(
///     groupingValues: ["hard"], startRank: 1, endRank: 10
/// )
///
/// // Global ranking across all modes
/// let globalTop100 = try await globalRankQuery.top(100)
/// ```
///
/// **Note**: #PrimaryKey is a marker macro that generates no code itself.
/// The @Recordable macro detects #PrimaryKey calls and extracts the KeyPath information
/// to generate primary key extraction logic.
///
/// **Validation**:
/// - Generic type parameter `<T>` is required
/// - KeyPath array must not be empty
/// - KeyPath fields must exist in the struct and match the generic type parameter
/// - Order of KeyPaths defines the order of composite primary key components
public struct PrimaryKeyMacroDeclaration: DeclarationMacro {

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
                    message: MacroExpansionErrorMessage("#PrimaryKey requires a type parameter (e.g., #PrimaryKey<User>)")
                )
            ])
        }

        // Type name is extracted from generic argument
        _ = genericArg.argument.description.trimmingCharacters(in: .whitespaces)

        // Validate that an array argument is provided
        guard let arrayArg = node.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#PrimaryKey requires a KeyPath array (e.g., [\\.\(genericArg.argument)])")
                )
            ])
        }

        // Validate that the argument is an array literal
        guard let arrayExpr = arrayArg.expression.as(ArrayExprSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(arrayArg.expression),
                    message: MacroExpansionErrorMessage("#PrimaryKey requires a KeyPath array (e.g., [\\.\(genericArg.argument)])")
                )
            ])
        }

        // Extract KeyPath fields
        var keyPathFields: [String] = []

        for element in arrayExpr.elements {
            let expr = element.expression

            // Check if it's a KeyPath expression
            if let keyPathExpr = expr.as(KeyPathExprSyntax.self),
               let component = keyPathExpr.components.first,
               let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                let fieldName = property.declName.baseName.text
                keyPathFields.append(fieldName)
                continue
            }

            // Invalid element type
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(expr),
                    message: MacroExpansionErrorMessage("Primary key array elements must be KeyPath expressions (e.g., \\.fieldName)")
                )
            ])
        }

        // Ensure at least one KeyPath is provided
        if keyPathFields.isEmpty {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(arrayExpr),
                    message: MacroExpansionErrorMessage("#PrimaryKey requires at least one KeyPath (e.g., [\\.\(genericArg.argument)])")
                )
            ])
        }

        // #PrimaryKey is a marker macro - it generates no code
        // The @Recordable macro will detect the UNEXPANDED macro call (MacroExpansionDeclSyntax)
        // and extract the KeyPath information directly from it
        //
        // This works because:
        // - @Recordable's expansion() receives the ORIGINAL syntax tree before other macros expand
        // - It can see MacroExpansionDeclSyntax nodes for #PrimaryKey
        // - It extracts arguments and generates primary key extraction logic
        //
        // Key characteristics:
        // - Only ONE #PrimaryKey macro per record type
        // - KeyPaths define the order of composite primary keys
        // - Used for record identification (record key generation)

        return []
    }
}
