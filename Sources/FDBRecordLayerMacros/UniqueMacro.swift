import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

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
///     #Unique<User>([\\.email])  // Email must be unique
///
///     @PrimaryKey var userID: Int64
///     var email: String
/// }
/// ```
public struct UniqueMacro: DeclarationMacro {

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
                    message: MacroExpansionErrorMessage("#Unique requires a type parameter (e.g., #Unique<User>)")
                )
            ])
        }

        let typeName = typeArg.argument.description.trimmingCharacters(in: .whitespaces)

        // Extract arguments - node.arguments is already LabeledExprListSyntax
        let arguments = node.arguments

        // Find the keyPaths argument
        guard let keyPathsArg = arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#Unique requires a keyPaths array argument")
                )
            ])
        }

        // Extract the key paths from the array
        let keyPaths = try extractKeyPaths(from: keyPathsArg.expression)

        // Find the optional name argument
        let indexName = arguments.first(where: { $0.label?.text == "name" })
            .flatMap { arg -> String? in
                // Extract string literal value
                if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                   let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                    return segment.content.text
                }
                return nil
            } ?? generateIndexName(typeName: typeName, keyPaths: keyPaths)

        // Generate the unique index declaration
        // IMPORTANT: Replace dots with double underscores to avoid name collisions
        // "Person_address.city_unique" -> "Person_address__city_unique" (not "Person_address_city_unique")
        // This prevents collision with "Person_address_city_unique" (from [\\.address, \\.city])
        let variableName = indexName.replacingOccurrences(of: ".", with: "__")

        let indexDecl: DeclSyntax = """
        static let \(raw: variableName): IndexDefinition = {
            IndexDefinition(
                name: "\(raw: indexName)",
                recordType: "\(raw: typeName)",
                fields: [\(raw: keyPaths.map { "\"\($0)\"" }.joined(separator: ", "))],
                unique: true
            )
        }()
        """

        return [indexDecl]
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
                // Extract ALL components from the key path for nested field support
                // KeyPath structure in SwiftSyntax:
                //   \Person.address.city
                //   - root: Optional<TypeExpr> = Person (not included in components)
                //   - components: [address, city]
                // So we DON'T need to skip anything - components already excludes the root type
                var pathComponents: [String] = []

                for component in keyPathExpr.components {
                    if let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                        pathComponents.append(property.declName.baseName.text)
                    }
                }

                // Join components with dots for nested paths
                // \Person.address.city -> ["address", "city"] -> "address.city"
                // \Person.email -> ["email"] -> "email"
                if !pathComponents.isEmpty {
                    keyPaths.append(pathComponents.joined(separator: "."))
                }
            }
        }

        return keyPaths
    }

    private static func generateIndexName(typeName: String, keyPaths: [String]) -> String {
        let fieldNames = keyPaths.joined(separator: "_")
        return "\(typeName)_\(fieldNames)_unique"
    }
}
