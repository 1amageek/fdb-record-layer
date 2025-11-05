import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the @Relationship macro
///
/// This peer macro defines a relationship to another record type.
/// Relationships maintain referential integrity between record types.
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///
///     @Relationship(deleteRule: .cascade, inverse: \\Order.userID)
///     var orders: [Int64] = []
/// }
///
/// @Recordable
/// struct Order {
///     @PrimaryKey var orderID: Int64
///
///     @Relationship(inverse: \\User.orders)
///     var userID: Int64
/// }
/// ```
public struct RelationshipMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Validate that this is applied to a property
        guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Relationship can only be applied to properties")
                )
            ])
        }

        // Extract the property name
        guard let binding = varDecl.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Relationship requires a named property")
                )
            ])
        }

        let propertyName = identifier.identifier.text

        // Extract arguments
        guard case let .argumentList(arguments) = node.arguments else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Relationship requires arguments")
                )
            ])
        }

        // Find the deleteRule argument (optional, defaults to .noAction)
        let deleteRuleStr = arguments.first(where: { $0.label?.text == "deleteRule" })
            .map { arg -> String in
                arg.expression.description.trimmingCharacters(in: .whitespaces)
            } ?? ".noAction"

        // Find the inverse argument (required)
        guard let inverseArg = arguments.first(where: { $0.label?.text == "inverse" }) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Relationship requires an 'inverse' argument")
                )
            ])
        }

        let inverseKeyPath = inverseArg.expression.description.trimmingCharacters(in: .whitespaces)

        // Generate relationship metadata as a static property
        // This will be accessible by the RecordMetaData for validation and cascade operations
        let relationshipMetadata: DeclSyntax = """
        static let _relationship_\(raw: propertyName) = RelationshipMetadata(
            propertyName: "\(raw: propertyName)",
            deleteRule: \(raw: deleteRuleStr),
            inverseKeyPath: \(raw: inverseKeyPath)
        )
        """

        // This macro generates metadata that can be collected by the RecordMetaData
        // The actual relationship enforcement happens at runtime in RecordStore
        return [relationshipMetadata]
    }
}

/// Metadata for a relationship between record types
public struct RelationshipMetadata {
    let propertyName: String
    let deleteRule: String  // Stored as string for macro purposes
    let inverseKeyPath: String
}
