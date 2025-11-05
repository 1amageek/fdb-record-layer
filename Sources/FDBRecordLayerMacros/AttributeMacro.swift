import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the @Attribute macro
///
/// This peer macro provides metadata about a property for schema evolution.
/// Used to track field renames and other schema changes.
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///
///     @Attribute(originalName: "username")
///     var name: String  // Renamed from "username"
/// }
/// ```
public struct AttributeMacro: PeerMacro {

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
                    message: MacroExpansionErrorMessage("@Attribute can only be applied to properties")
                )
            ])
        }

        // Extract the property name
        guard let binding = varDecl.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Attribute requires a named property")
                )
            ])
        }

        let propertyName = identifier.identifier.text

        // Extract arguments
        guard case let .argumentList(arguments) = node.arguments else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Attribute requires arguments")
                )
            ])
        }

        // Find the originalName argument
        guard let originalNameArg = arguments.first(where: { $0.label?.text == "originalName" }) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Attribute requires an 'originalName' argument")
                )
            ])
        }

        // Extract the original name from the string literal
        guard let stringLiteral = originalNameArg.expression.as(StringLiteralExprSyntax.self),
              let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: originalNameArg.expression,
                    message: MacroExpansionErrorMessage("originalName must be a string literal")
                )
            ])
        }

        let originalName = segment.content.text

        // Generate attribute metadata as a static property
        // This will be accessible during deserialization to handle field renames
        let attributeMetadata: DeclSyntax = """
        static let _attribute_\(raw: propertyName) = AttributeMetadata(
            propertyName: "\(raw: propertyName)",
            originalName: "\(raw: originalName)"
        )
        """

        // This macro generates metadata that can be used during deserialization
        // to handle schema evolution (e.g., field renames)
        return [attributeMetadata]
    }
}

/// Metadata for property attributes used in schema evolution
public struct AttributeMetadata {
    let propertyName: String
    let originalName: String
}
