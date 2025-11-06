import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

/// Implementation of the #Index macro
///
/// This freestanding macro generates index metadata declarations.
/// It analyzes the provided KeyPaths and creates corresponding index definitions
/// that can be registered with the RecordMetaData.
///
/// Usage:
/// ```swift
/// @Recordable
/// struct User {
///     #Index<User>([\.email])
///     #Index<User>([\.country, \.city], name: "location_index")
///
///     @PrimaryKey var userID: Int64
///     var email: String
///     var country: String
///     var city: String
/// }
/// ```
///
/// **Note**: #Index is a marker macro that generates no code itself.
/// The @Recordable macro detects #Index calls and generates IndexDefinitions in the extension.
/// This approach avoids circular reference errors while using KeyPaths.
public struct IndexMacro: DeclarationMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // #Index is a marker macro - it generates no code
        // The @Recordable macro will detect the UNEXPANDED macro call (MacroExpansionDeclSyntax)
        // and extract the KeyPath information directly from it
        //
        // This works because:
        // - @Recordable's expansion() receives the ORIGINAL syntax tree before other macros expand
        // - It can see MacroExpansionDeclSyntax nodes for #Index/#Unique
        // - It extracts arguments and generates IndexDefinition properties in the extension

        return []
    }
}
