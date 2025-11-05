import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the @Transient macro
///
/// This is a peer macro that marks a property as transient (not persisted).
/// It doesn't generate any code itself - it's used by @Recordable macro
/// to identify which fields should be excluded from serialization.
public struct TransientMacro: PeerMacro {

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
                    message: MacroExpansionErrorMessage("@Transient can only be applied to properties")
                )
            ])
        }

        // This macro doesn't generate any peer declarations
        // It's purely metadata for the @Recordable macro
        return []
    }
}
