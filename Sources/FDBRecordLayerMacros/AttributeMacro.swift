import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the @Attribute macro
///
/// This peer macro provides metadata about a property for schema evolution and constraints.
/// Supports SwiftData-compliant variadic options pattern.
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     #PrimaryKey<User>([\.userID])
///
///     @Attribute(.unique)
///     var email: String
///
///     @Attribute(originalName: "username")
///     var name: String
///
///     @Attribute(.unique, originalName: "old_email", hashModifier: "v2")
///     var primaryEmail: String
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

        // Extract arguments (may be empty for @Attribute with no args)
        guard case let .argumentList(arguments) = node.arguments else {
            // No arguments - valid, just generate empty metadata
            return generateMetadata(
                propertyName: propertyName,
                options: [],
                originalName: nil,
                hashModifier: nil
            )
        }

        // Parse options, originalName, and hashModifier
        var options: [String] = []
        var originalName: String? = nil
        var hashModifier: String? = nil

        for argument in arguments {
            if let label = argument.label?.text {
                // Named parameters: originalName, hashModifier
                switch label {
                case "originalName":
                    originalName = try extractStringLiteral(from: argument.expression)
                case "hashModifier":
                    hashModifier = try extractStringLiteral(from: argument.expression)
                default:
                    throw DiagnosticsError(diagnostics: [
                        Diagnostic(
                            node: argument,
                            message: MacroExpansionErrorMessage("Unknown parameter '\(label)'")
                        )
                    ])
                }
            } else {
                // Unlabeled variadic arguments: options
                let option = try extractOption(from: argument.expression)
                options.append(option)
            }
        }

        return generateMetadata(
            propertyName: propertyName,
            options: options,
            originalName: originalName,
            hashModifier: hashModifier
        )
    }

    /// Extract string literal value from expression
    private static func extractStringLiteral(from expression: ExprSyntax) throws -> String {
        guard let stringLiteral = expression.as(StringLiteralExprSyntax.self),
              let segment = stringLiteral.segments.first?.cast(StringSegmentSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: expression,
                    message: MacroExpansionErrorMessage("Expected a string literal")
                )
            ])
        }
        return segment.content.text
    }

    /// Extract option enum case from expression
    private static func extractOption(from expression: ExprSyntax) throws -> String {
        // Handle .unique, .someOtherOption patterns
        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text
        }

        throw DiagnosticsError(diagnostics: [
            Diagnostic(
                node: expression,
                message: MacroExpansionErrorMessage("Expected an attribute option (e.g., .unique)")
            )
        ])
    }

    /// Generate metadata declaration
    private static func generateMetadata(
        propertyName: String,
        options: [String],
        originalName: String?,
        hashModifier: String?
    ) -> [DeclSyntax] {
        var metadataParts: [String] = []

        metadataParts.append("propertyName: \"\(propertyName)\"")

        if !options.isEmpty {
            let optionsArray = options.map { "\"\($0)\"" }.joined(separator: ", ")
            metadataParts.append("options: [\(optionsArray)]")
        } else {
            metadataParts.append("options: []")
        }

        if let originalName = originalName {
            metadataParts.append("originalName: \"\(originalName)\"")
        } else {
            metadataParts.append("originalName: nil")
        }

        if let hashModifier = hashModifier {
            metadataParts.append("hashModifier: \"\(hashModifier)\"")
        } else {
            metadataParts.append("hashModifier: nil")
        }

        let metadataContent = metadataParts.joined(separator: ", ")

        let attributeMetadata: DeclSyntax = """
        static let _attribute_\(raw: propertyName) = AttributeMetadata(
            \(raw: metadataContent)
        )
        """

        return [attributeMetadata]
    }
}

/// Metadata for property attributes used in schema evolution and constraints
public struct AttributeMetadata: Sendable {
    let propertyName: String
    let options: [String]  // e.g., ["unique"]
    let originalName: String?
    let hashModifier: String?
}
