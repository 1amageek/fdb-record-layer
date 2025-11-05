import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the @PrimaryKey macro
///
/// This is a peer macro that marks a property as a primary key.
/// It doesn't generate any code itself - it's used by @Recordable macro
/// to identify which fields form the primary key.
public struct PrimaryKeyMacro: PeerMacro {

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
                    message: MacroExpansionErrorMessage("@PrimaryKey can only be applied to properties")
                )
            ])
        }

        // This macro doesn't generate any peer declarations
        // It's purely metadata for the @Recordable macro
        return []
    }
}
