import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the @Default macro
///
/// This is a peer macro that provides a default value for a property.
/// Used for schema evolution when adding new fields to existing records.
public struct DefaultMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Validate that this is applied to a property
        guard declaration.is(VariableDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Default can only be applied to properties")
                )
            ])
        }

        // Validate that a value argument was provided
        guard case let .argumentList(arguments) = node.arguments,
              let _ = arguments.first(where: { arg in
                  arg.label?.text == "value"
              }) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Default requires a 'value' argument")
                )
            ])
        }

        // This macro doesn't generate any peer declarations
        // The default value is stored in the macro attribute and can be
        // accessed by the @Recordable macro during deserialization
        return []
    }
}
