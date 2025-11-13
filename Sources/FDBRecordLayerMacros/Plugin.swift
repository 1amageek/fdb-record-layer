import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct FDBRecordLayerMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RecordableMacro.self,
        PrimaryKeyMacroDeclaration.self,  // #PrimaryKey
        TransientMacro.self,
        DefaultMacro.self,
        IndexMacro.self,
        UniqueMacro.self,
        DirectoryMacro.self,
        RelationshipMacro.self,
        AttributeMacro.self,
    ]
}
