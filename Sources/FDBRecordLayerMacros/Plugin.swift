import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct FDBRecordLayerMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RecordableMacro.self,
        PrimaryKeyMacro.self,
        TransientMacro.self,
        DefaultMacro.self,
        IndexMacro.self,
        UniqueMacro.self,
        FieldOrderMacro.self,
        SubspaceMacro.self,
        RelationshipMacro.self,
        AttributeMacro.self,
    ]
}
