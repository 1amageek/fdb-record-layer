import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

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
///     #Unique<User>([\.email])  // Email must be unique
///
///     @PrimaryKey var userID: Int64
///     var email: String
/// }
/// ```
///
/// **Note**: #Unique is a marker macro that generates no code itself.
/// The @Recordable macro detects #Unique calls and generates IndexDefinitions in the extension.
/// This approach avoids circular reference errors while using KeyPaths.
public struct UniqueMacro: DeclarationMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // #Unique is a marker macro - it generates no code
        // The @Recordable macro will detect the UNEXPANDED macro call (MacroExpansionDeclSyntax)
        // and extract the KeyPath information directly from it
        //
        // This works because:
        // - @Recordable's expansion() receives the ORIGINAL syntax tree before other macros expand
        // - It can see MacroExpansionDeclSyntax nodes for #Index/#Unique
        // - It extracts arguments and generates IndexDefinition properties with unique: true in the extension

        return []
    }
}
