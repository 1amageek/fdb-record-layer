import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

/// Implementation of the @Recordable macro
///
/// This macro generates:
/// - Recordable protocol conformance
/// - Static metadata properties (recordName, primaryKeyFields, allFields)
/// - Protobuf serialization/deserialization methods
/// - Field extraction methods
public struct RecordableMacro: MemberMacro, ExtensionMacro {

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Ensure this is a struct
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: node,
                    message: MacroExpansionErrorMessage("@Recordable can only be applied to structs")
                )
            ])
        }

        let typeName = structDecl.name.text
        let members = structDecl.memberBlock.members

        // Extract field information
        let fields = try extractFields(from: members, context: context)
        let primaryKeyFields = fields.filter { $0.isPrimaryKey }
        let persistentFields = fields.filter { !$0.isTransient }

        // Validate: must have at least one primary key
        guard !primaryKeyFields.isEmpty else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: structDecl,
                    message: MacroExpansionErrorMessage("@Recordable struct must have at least one @PrimaryKey field")
                )
            ])
        }

        // Generate the extension members
        var results: [DeclSyntax] = []

        // Generate static fieldName method for KeyPath resolution
        results.append(generateFieldNameMethod(typeName: typeName, fields: persistentFields))

        return results
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {

        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            return []
        }

        let structName = structDecl.name.text
        let members = structDecl.memberBlock.members

        // Extract recordName from macro arguments (if provided)
        let recordName = extractRecordName(from: node) ?? structName

        // Extract field information
        let fields = try extractFields(from: members, context: context)
        let primaryKeyFields = fields.filter { $0.isPrimaryKey }
        let persistentFields = fields.filter { !$0.isTransient }

        // Detect #Subspace metadata
        let subspaceMetadata = extractSubspaceMetadata(from: members)

        // Extract index information from #Index/#Unique macro calls
        // Note: We need to check ALL members, including those added by other macros
        // Use declaration.memberBlock.members to get the complete member list
        let allMembers = declaration.memberBlock.members
        let indexInfo = extractIndexInfo(from: allMembers)

        // Generate Recordable conformance
        let recordableExtension = try generateRecordableExtension(
            typeName: structName,
            recordName: recordName,
            fields: persistentFields,
            primaryKeyFields: primaryKeyFields,
            subspaceMetadata: subspaceMetadata,
            indexInfo: indexInfo
        )

        return [recordableExtension]
    }

    // MARK: - Helper Methods

    /// Extracts recordName from @Recordable macro arguments
    /// Returns nil if not specified (defaults to struct name)
    private static func extractRecordName(from node: AttributeSyntax) -> String? {
        guard let arguments = node.arguments,
              case .argumentList(let argumentList) = arguments else {
            return nil
        }

        for argument in argumentList {
            // Look for recordName argument
            if let label = argument.label?.text, label == "recordName",
               let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                return segment.content.text
            }
        }

        return nil
    }

    /// Subspace metadata extracted from #Subspace macro
    private struct SubspaceMetadata {
        let pathTemplate: String
        let placeholders: [String]
    }

    /// Extracts #Subspace metadata from struct members by looking for #Subspace macro calls
    private static func extractSubspaceMetadata(
        from members: MemberBlockItemListSyntax
    ) -> SubspaceMetadata? {
        for member in members {
            // Look for #Subspace macro expansion
            guard let macroExpansion = member.decl.as(MacroExpansionDeclSyntax.self),
                  macroExpansion.macroName.text == "Subspace" else {
                continue
            }

            // Extract the path template argument
            guard let pathArg = macroExpansion.arguments.first,
                  let stringLiteral = pathArg.expression.as(StringLiteralExprSyntax.self),
                  let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) else {
                continue
            }

            let pathTemplate = segment.content.text

            // Parse placeholders from the template
            let placeholders = extractPlaceholders(from: pathTemplate)

            return SubspaceMetadata(pathTemplate: pathTemplate, placeholders: placeholders)
        }

        return nil
    }

    /// Extracts placeholder names from a path template
    /// Example: "accounts/{accountID}/users/{userID}" -> ["accountID", "userID"]
    private static func extractPlaceholders(from template: String) -> [String] {
        var placeholders: [String] = []
        var currentPlaceholder = ""
        var insidePlaceholder = false

        for char in template {
            if char == "{" {
                insidePlaceholder = true
                currentPlaceholder = ""
            } else if char == "}" {
                if insidePlaceholder && !currentPlaceholder.isEmpty {
                    placeholders.append(currentPlaceholder)
                }
                insidePlaceholder = false
                currentPlaceholder = ""
            } else if insidePlaceholder {
                currentPlaceholder.append(char)
            }
        }

        return placeholders
    }

    /// Extracts IndexDefinition static property names from struct members
    /// These are generated by #Index and #Unique macros
    /// Extract index information from marker properties generated by #Index and #Unique macros
    ///
    /// This method scans the struct body for marker properties (static let __fdb_index_* or __fdb_unique_*)
    /// that were generated by #Index/#Unique macros, and parses the encoded information.
    ///
    /// Marker format: "__INDEX__:TypeName:field1,field2:customName:unique"
    /// Example: "__INDEX__:User:email::false" or "__UNIQUE__:User:email,username::true"
    private static func extractIndexInfo(
        from members: MemberBlockItemListSyntax
    ) -> [IndexInfo] {
        var indexes: [IndexInfo] = []

        for member in members {
            // Look for macro expansion declarations (#Index or #Unique)
            // These appear BEFORE macro expansion as MacroExpansionDeclSyntax
            guard let macroDecl = member.decl.as(MacroExpansionDeclSyntax.self) else {
                continue
            }

            let macroName = macroDecl.macroName.text

            // Check if it's #Index or #Unique
            guard macroName == "Index" || macroName == "Unique" else {
                continue
            }

            let isUnique = (macroName == "Unique")

            // Extract type name from generic argument <User>
            guard let genericArgs = macroDecl.genericArgumentClause,
                  let firstArg = genericArgs.arguments.first else {
                continue
            }
            let typeName = firstArg.argument.description.trimmingCharacters(in: CharacterSet.whitespaces)

            // Extract arguments
            let arguments = macroDecl.arguments

            // Extract custom name from 'name:' parameter (if present)
            let customName = arguments.first(where: { $0.label?.text == "name" })
                .flatMap { arg -> String? in
                    if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                       let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                        return segment.content.text
                    }
                    return nil
                }

            // Process each KeyPath array argument
            for argument in arguments {
                // Skip named 'name:' parameter
                if argument.label?.text == "name" {
                    continue
                }

                let fields = extractFieldNamesFromKeyPaths(argument.expression)

                if !fields.isEmpty {
                    indexes.append(IndexInfo(
                        fields: fields,
                        isUnique: isUnique,
                        customName: customName,
                        typeName: typeName
                    ))
                }
            }
        }

        return indexes
    }

    /// Extract field names from KeyPath array expression
    /// Example: [\.email] -> ["email"]
    /// Example: [\.country, \.city] -> ["country", "city"]
    private static func extractFieldNamesFromKeyPaths(_ expression: ExprSyntax) -> [String] {
        guard let arrayExpr = expression.as(ArrayExprSyntax.self) else {
            return []
        }

        var fieldNames: [String] = []

        for element in arrayExpr.elements {
            if let keyPathExpr = element.expression.as(KeyPathExprSyntax.self) {
                // Extract components from KeyPath
                // \User.email -> components: ["email"]
                // \User.address.city -> components: ["address", "city"]
                var pathComponents: [String] = []

                for component in keyPathExpr.components {
                    if let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                        pathComponents.append(property.declName.baseName.text)
                    }
                }

                // Join with dots for nested paths
                if !pathComponents.isEmpty {
                    fieldNames.append(pathComponents.joined(separator: "."))
                }
            }
        }

        return fieldNames
    }

    private static func extractFields(
        from members: MemberBlockItemListSyntax,
        context: some MacroExpansionContext
    ) throws -> [FieldInfo] {
        var fields: [FieldInfo] = []

        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard let binding = varDecl.bindings.first else { continue }
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }

            let fieldName = identifier.identifier.text

            // Check for @PrimaryKey
            let isPrimaryKey = varDecl.attributes.contains { attr in
                attr.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "PrimaryKey"
            }

            // Check for @Transient
            let isTransient = varDecl.attributes.contains { attr in
                attr.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Transient"
            }

            // Get type
            guard let type = binding.typeAnnotation?.type else { continue }

            let typeString = type.description.trimmingCharacters(in: .whitespaces)
            let typeInfo = analyzeType(typeString)

            fields.append(FieldInfo(
                name: fieldName,
                type: typeString,
                typeInfo: typeInfo,
                isPrimaryKey: isPrimaryKey,
                isTransient: isTransient
            ))
        }

        return fields
    }

    private static func generateFieldNameMethod(
        typeName: String,
        fields: [FieldInfo]
    ) -> DeclSyntax {
        let cases = fields.map { field in
            "if keyPath == \\\(typeName).\(field.name) { return \"\(field.name)\" }"
        }.joined(separator: "\n        ")

        return """
        public static func fieldName<Value>(for keyPath: KeyPath<\(raw: typeName), Value>) -> String {
            \(raw: cases)
            return "\\(keyPath)"
        }
        """
    }

    /// Generate IndexDefinition static properties and indexDefinitions array
    ///
    /// Returns a tuple of:
    /// - indexStaticProperties: Static IndexDefinition properties (e.g., `static let User_email_index = ...`)
    /// - indexDefinitionsProperty: The `indexDefinitions` array property
    private static func generateIndexDefinitions(
        typeName: String,
        indexInfo: [IndexInfo]
    ) -> (indexStaticProperties: String, indexDefinitionsProperty: String) {
        guard !indexInfo.isEmpty else {
            return ("", "")
        }

        // Generate static IndexDefinition properties with getter to avoid circular reference
        let staticProperties = indexInfo.map { info in
            let varName = info.variableName()
            let indexName = info.indexName()
            let keyPathsLiteral = info.fields.map { "\\\(typeName).\($0)" }.joined(separator: ", ")
            let unique = info.isUnique ? "true" : "false"

            return """

                public static var \(varName): IndexDefinition {
                    IndexDefinition(
                        name: "\(indexName)",
                        keyPaths: [\(keyPathsLiteral)] as [PartialKeyPath<\(typeName)>],
                        unique: \(unique)
                    )
                }
            """
        }.joined()

        // Generate indexDefinitions array property
        let indexNames = indexInfo.map { $0.variableName() }.joined(separator: ", ")
        let indexDefinitionsProperty = """

            public static var indexDefinitions: [IndexDefinition] {
                [\(indexNames)]
            }
        """

        return (staticProperties, indexDefinitionsProperty)
    }

    /// Generates store() methods based on #Subspace metadata
    private static func generateStoreMethods(
        typeName: String,
        fields: [FieldInfo],
        subspaceMetadata: SubspaceMetadata?
    ) -> String {
        var methods: [String] = []

        // Always generate basic store(in:path:) method
        methods.append("""

            /// Creates a RecordStore for this type with a custom path
            ///
            /// - Parameters:
            ///   - container: The RecordContainer
            ///   - path: Custom subspace path (e.g., "users" or "accounts/acct-001/users")
            /// - Returns: RecordStore configured with the specified path
            public static func store(
                in container: RecordContainer,
                path: String
            ) -> RecordStore<\(typeName)> {
                return container.store(for: \(typeName).self, path: path)
            }
        """)

        // Generate type-safe method if #Subspace metadata exists
        if let metadata = subspaceMetadata {
            if metadata.placeholders.isEmpty {
                // Static path - no parameters
                methods.append("""

                /// Creates a RecordStore for this type using the defined subspace path
                ///
                /// Subspace path: "\(metadata.pathTemplate)"
                ///
                /// - Parameter container: The RecordContainer
                /// - Returns: RecordStore configured with the subspace path
                public static func store(
                    in container: RecordContainer
                ) -> RecordStore<\(typeName)> {
                    return container.store(for: \(typeName).self, path: "\(metadata.pathTemplate)")
                }
                """)
            } else {
                // Dynamic path - generate parameters with field types
                // Match placeholder names to field types
                let parameters = metadata.placeholders.map { placeholder -> String in
                    if let field = fields.first(where: { $0.name == placeholder }) {
                        return "\(placeholder): \(field.type)"
                    } else {
                        // Fallback to String if field not found
                        return "\(placeholder): String"
                    }
                }.joined(separator: ", ")

                // Convert template to Swift string interpolation
                var interpolatedPath = metadata.pathTemplate
                for placeholder in metadata.placeholders {
                    interpolatedPath = interpolatedPath.replacingOccurrences(
                        of: "{\(placeholder)}",
                        with: "\\(\(placeholder))"
                    )
                }

                let paramDocs = metadata.placeholders.map {
                    "    ///   - \($0): Path component value"
                }.joined(separator: "\n")

                methods.append("""

                /// Creates a RecordStore for this type using the defined subspace path
                ///
                /// Subspace path template: "\(metadata.pathTemplate)"
                ///
                /// - Parameters:
                ///   - container: The RecordContainer
                \(paramDocs)
                /// - Returns: RecordStore configured with the interpolated subspace path
                public static func store(
                    in container: RecordContainer,
                    \(parameters)
                ) -> RecordStore<\(typeName)> {
                    let path = "\(interpolatedPath)"
                    return container.store(for: \(typeName).self, path: path)
                }
                """)
            }
        }

        return methods.joined(separator: "\n")
    }

    private static func generateRecordableExtension(
        typeName: String,
        recordName: String,
        fields: [FieldInfo],
        primaryKeyFields: [FieldInfo],
        subspaceMetadata: SubspaceMetadata?,
        indexInfo: [IndexInfo]
    ) throws -> ExtensionDeclSyntax {

        let fieldNames = fields.map { "\"\($0.name)\"" }.joined(separator: ", ")
        let primaryKeyNames = primaryKeyFields.map { "\"\($0.name)\"" }.joined(separator: ", ")

        // Generate field numbers (1-indexed)
        let fieldNumberCases = fields.enumerated().map { index, field in
            "case \"\(field.name)\": return \(index + 1)"
        }.joined(separator: "\n            ")

        // Generate toProtobuf
        let serializeFields = fields.enumerated().map { index, field in
            generateSerializeField(field: field, fieldNumber: index + 1)
        }.joined(separator: "\n        ")

        // Generate fromProtobuf
        let deserializeFields = fields.enumerated().map { index, field in
            generateDeserializeField(field: field, fieldNumber: index + 1)
        }.joined(separator: "\n            ")

        // Generate required field validation
        let requiredFieldValidation = generateRequiredFieldValidation(fields: fields)

        let initFields = fields.map { field in
            "\(field.name): \(field.name)"
        }.joined(separator: ", ")

        // Generate extractField
        let extractFieldCases = fields.map { field in
            generateExtractFieldCase(field: field)
        }.joined(separator: "\n            ")

        // Generate nested field handling for custom types
        let nestedFieldHandling = generateNestedFieldHandling(fields: fields)

        // Generate extractPrimaryKey
        let primaryKeyExtraction = primaryKeyFields.map { field in
            let typeInfo = field.typeInfo
            // Convert Int32/UInt32 to Int64 for TupleElement conformance
            if case .primitive(let primitiveType) = typeInfo.category {
                switch primitiveType {
                case .int32, .uint32:
                    return "Int64(self.\(field.name))"
                default:
                    return "self.\(field.name)"
                }
            }
            return "self.\(field.name)"
        }.joined(separator: ", ")

        // Generate store() methods based on #Subspace metadata
        let storeMethods = generateStoreMethods(typeName: typeName, fields: fields, subspaceMetadata: subspaceMetadata)

        // Generate IndexDefinition static properties and indexDefinitions array
        let (indexStaticProperties, indexDefinitionsProperty) = generateIndexDefinitions(
            typeName: typeName,
            indexInfo: indexInfo
        )

        let extensionCode: DeclSyntax = """
        extension \(raw: typeName): Recordable {
            public static var recordName: String { "\(raw: recordName)" }

            public static var primaryKeyFields: [String] { [\(raw: primaryKeyNames)] }

            public static var allFields: [String] { [\(raw: fieldNames)] }
            \(raw: indexStaticProperties)\(raw: indexDefinitionsProperty)

            public static func fieldNumber(for fieldName: String) -> Int? {
                switch fieldName {
                \(raw: fieldNumberCases)
                default: return nil
                }
            }

            public func toProtobuf() throws -> Data {
                var data = Data()

                func encodeVarint(_ value: UInt64) -> [UInt8] {
                    var result: [UInt8] = []
                    var n = value
                    while n >= 0x80 {
                        result.append(UInt8(n & 0x7F) | 0x80)
                        n >>= 7
                    }
                    result.append(UInt8(n))
                    return result
                }

                func encodeItem(_ item: Any) throws -> Data {
                    if let recordable = item as? any Recordable {
                        return try recordable.toProtobuf()
                    }

                    var itemData = Data()

                    // Varint types
                    if let value = item as? Bool {
                        itemData.append(contentsOf: encodeVarint(value ? 1 : 0))
                    } else if let value = item as? Int32 {
                        itemData.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
                    } else if let value = item as? UInt32 {
                        itemData.append(contentsOf: encodeVarint(UInt64(value)))
                    } else if let value = item as? Int64 {
                        itemData.append(contentsOf: encodeVarint(UInt64(bitPattern: value)))
                    } else if let value = item as? UInt64 {
                        itemData.append(contentsOf: encodeVarint(value))
                    }
                    // Fixed 32-bit
                    else if let value = item as? Float {
                        let bits = value.bitPattern
                        itemData.append(UInt8(truncatingIfNeeded: bits))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 8))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 16))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 24))
                    }
                    // Fixed 64-bit
                    else if let value = item as? Double {
                        let bits = value.bitPattern
                        itemData.append(UInt8(truncatingIfNeeded: bits))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 8))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 16))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 24))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 32))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 40))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 48))
                        itemData.append(UInt8(truncatingIfNeeded: bits >> 56))
                    }
                    // Length-delimited
                    else if let value = item as? String {
                        itemData.append(value.data(using: .utf8) ?? Data())
                    } else if let value = item as? Data {
                        itemData.append(value)
                    } else {
                        // Unknown type - throw error for safety
                        throw RecordLayerError.serializationFailed("Unknown type in encodeItem: \\(type(of: item))")
                    }

                    return itemData
                }

                func encodeValue(_ value: Any) throws -> Data {
                    return try encodeItem(value)
                }

                \(raw: serializeFields)
                return data
            }

            public static func fromProtobuf(_ data: Data) throws -> \(raw: typeName) {
                var offset = 0
                \(raw: deserializeFields)

                func decodeVarint(_ data: Data, offset: inout Int) throws -> UInt64 {
                    var result: UInt64 = 0
                    var shift: UInt64 = 0
                    while offset < data.count {
                        let byte = data[offset]
                        offset += 1
                        result |= UInt64(byte & 0x7F) << shift
                        if byte & 0x80 == 0 {
                            return result
                        }
                        shift += 7
                        if shift >= 64 {
                            throw RecordLayerError.serializationFailed("Varint too long")
                        }
                    }
                    throw RecordLayerError.serializationFailed("Unexpected end of data")
                }

                // Parse protobuf data
                while offset < data.count {
                    let tag = try decodeVarint(data, offset: &offset)
                    let fieldNumber = Int(tag >> 3)
                    let wireType = Int(tag & 0x7)

                    switch fieldNumber {
                    \(raw: generateDecodeSwitch(fields: fields))
                    default:
                        // Skip unknown field
                        try skipField(data: data, offset: &offset, wireType: wireType)
                    }
                }

                func skipField(data: Data, offset: inout Int, wireType: Int) throws {
                    switch wireType {
                    case 0: // Varint
                        _ = try decodeVarint(data, offset: &offset)
                    case 1: // 64-bit
                        offset += 8
                    case 2: // Length-delimited
                        let length = try decodeVarint(data, offset: &offset)
                        offset += Int(length)
                    case 5: // 32-bit
                        offset += 4
                    default:
                        throw RecordLayerError.serializationFailed("Unknown wire type: \\(wireType)")
                    }
                }

                // Validate required fields
                \(raw: requiredFieldValidation)

                return \(raw: typeName)(\(raw: initFields))
            }

            public func extractField(_ fieldName: String) -> [any TupleElement] {
                // Handle nested field paths (e.g., "address.city")
                if fieldName.contains(".") {
                    let components = fieldName.split(separator: ".", maxSplits: 1)
                    guard components.count == 2 else { return [] }

                    let firstField = String(components[0])
                    let remainingPath = String(components[1])

                    switch firstField {
                    \(raw: nestedFieldHandling)
                    default:
                        _ = remainingPath  // Suppress unused warning when no custom fields
                        return []
                    }
                }

                // Handle direct field access
                switch fieldName {
                \(raw: extractFieldCases)
                default: return []
                }
            }

            public func extractPrimaryKey() -> Tuple {
                return Tuple([\(raw: primaryKeyExtraction)])
            }

            \(raw: storeMethods)
        }
        """

        guard let ext = extensionCode.as(ExtensionDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(extensionCode),
                    message: MacroExpansionErrorMessage("Failed to generate extension")
                )
            ])
        }

        return ext
    }

    private static func generateSerializeField(field: FieldInfo, fieldNumber: Int) -> String {
        let wireType = getWireType(for: field.type)
        let tag = (fieldNumber << 3) | wireType

        switch field.type {
        case "Int32":
            return """
            // Field \(fieldNumber): \(field.name) (Int32)
            data.append(contentsOf: encodeVarint(\(tag)))
            data.append(contentsOf: encodeVarint(UInt64(truncatingIfNeeded: UInt32(bitPattern: self.\(field.name)))))
            """

        case "Int64":
            return """
            // Field \(fieldNumber): \(field.name) (Int64)
            data.append(contentsOf: encodeVarint(\(tag)))
            data.append(contentsOf: encodeVarint(UInt64(bitPattern: self.\(field.name))))
            """

        case "UInt32":
            return """
            // Field \(fieldNumber): \(field.name) (UInt32)
            data.append(contentsOf: encodeVarint(\(tag)))
            data.append(contentsOf: encodeVarint(UInt64(self.\(field.name))))
            """

        case "UInt64":
            return """
            // Field \(fieldNumber): \(field.name) (UInt64)
            data.append(contentsOf: encodeVarint(\(tag)))
            data.append(contentsOf: encodeVarint(self.\(field.name)))
            """

        case "Bool":
            return """
            // Field \(fieldNumber): \(field.name) (Bool)
            data.append(contentsOf: encodeVarint(\(tag)))
            data.append(contentsOf: encodeVarint(self.\(field.name) ? 1 : 0))
            """

        case "String":
            return """
            // Field \(fieldNumber): \(field.name) (String)
            data.append(contentsOf: encodeVarint(\(tag)))
            let \(field.name)Data = self.\(field.name).data(using: .utf8)!
            data.append(contentsOf: encodeVarint(UInt64(\(field.name)Data.count)))
            data.append(\(field.name)Data)
            """

        case "Data":
            return """
            // Field \(fieldNumber): \(field.name) (Data)
            data.append(contentsOf: encodeVarint(\(tag)))
            data.append(contentsOf: encodeVarint(UInt64(self.\(field.name).count)))
            data.append(self.\(field.name))
            """

        case "Double":
            return """
            // Field \(fieldNumber): \(field.name) (Double)
            data.append(contentsOf: encodeVarint(\(tag)))
            let \(field.name)Bits = self.\(field.name).bitPattern
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 8))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 16))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 24))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 32))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 40))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 48))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 56))
            """

        case "Float":
            return """
            // Field \(fieldNumber): \(field.name) (Float)
            data.append(contentsOf: encodeVarint(\(tag)))
            let \(field.name)Bits = self.\(field.name).bitPattern
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 8))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 16))
            data.append(UInt8(truncatingIfNeeded: \(field.name)Bits >> 24))
            """

        default:
            // Use typeInfo for accurate type detection
            // Check for Optional<Array<T>> first (both isArray and isOptional are true)
            if field.typeInfo.isOptional && field.typeInfo.isArray {
                return generateOptionalArraySerialize(field: field, fieldNumber: fieldNumber)
            } else if field.typeInfo.isArray {
                return generateArraySerialize(field: field, fieldNumber: fieldNumber)
            } else if field.typeInfo.isOptional {
                return generateOptionalSerialize(field: field, fieldNumber: fieldNumber)
            } else {
                // Assume nested message
                return """
                // Field \(fieldNumber): \(field.name) (\(field.type))
                data.append(contentsOf: encodeVarint(\(tag)))
                let nested = try self.\(field.name).toProtobuf()
                data.append(contentsOf: encodeVarint(UInt64(nested.count)))
                data.append(nested)
                """
            }
        }
    }

    private static func generateDeserializeField(field: FieldInfo, fieldNumber: Int) -> String {
        let typeInfo = field.typeInfo

        // Optional<Array<T>>: initialize to nil
        if typeInfo.isOptional && typeInfo.isArray {
            return "var \(field.name): \(field.type) = nil"
        }

        // Arrays are always initialized to empty array
        if typeInfo.isArray {
            return "var \(field.name): \(field.type) = []"
        }

        // Optional types are always initialized to nil
        if typeInfo.isOptional {
            return "var \(field.name): \(field.type) = nil"
        }

        // Primitive types have appropriate defaults
        if case .primitive(let primitiveType) = typeInfo.category {
            let defaultValue = getPrimitiveDefaultValue(primitiveType)
            return "var \(field.name): \(typeInfo.baseType) = \(defaultValue)"
        }

        // Custom types (non-optional) are initialized to nil temporarily
        // They will be checked for presence after parsing
        return "var \(field.name): \(typeInfo.baseType)? = nil"
    }

    private static func getPrimitiveDefaultValue(_ primitiveType: PrimitiveType) -> String {
        switch primitiveType {
        case .int32, .int64, .uint32, .uint64:
            return "0"
        case .bool:
            return "false"
        case .string:
            return "\"\""
        case .data:
            return "Data()"
        case .double, .float:
            return "0.0"
        }
    }

    private static func generateOptionalArraySerialize(field: FieldInfo, fieldNumber: Int) -> String {
        let typeInfo = field.typeInfo

        // Get element type from the array
        guard let elementTypeBox = typeInfo.arrayElementType else {
            // Fallback: should not happen
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<Array>) - fallback
            if let array = self.\(field.name) {
                for item in array {
                    data.append(contentsOf: encodeVarint(\(tag)))
                    let itemData = try encodeItem(item)
                    data.append(contentsOf: encodeVarint(UInt64(itemData.count)))
                    data.append(itemData)
                }
            }
            """
        }

        let elementType = elementTypeBox.value

        // Check if element type is primitive
        guard case .primitive(let primitiveType) = elementType.category else {
            // Custom types: unpacked repeated
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[\(elementType.baseType)]>)
            if let array = self.\(field.name) {
                for item in array {
                    data.append(contentsOf: encodeVarint(\(tag)))
                    let nested = try item.toProtobuf()
                    data.append(contentsOf: encodeVarint(UInt64(nested.count)))
                    data.append(nested)
                }
            }
            """
        }

        // Primitive types: use packed repeated for numeric types
        switch primitiveType {
        // Varint types - packed
        case .int32:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[Int32]>) - packed
            if let array = self.\(field.name), !array.isEmpty {
                var packedData = Data()
                for item in array {
                    packedData.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(item))))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .int64:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[Int64]>) - packed
            if let array = self.\(field.name), !array.isEmpty {
                var packedData = Data()
                for item in array {
                    packedData.append(contentsOf: encodeVarint(UInt64(bitPattern: item)))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .uint32:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[UInt32]>) - packed
            if let array = self.\(field.name), !array.isEmpty {
                var packedData = Data()
                for item in array {
                    packedData.append(contentsOf: encodeVarint(UInt64(item)))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .uint64:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[UInt64]>) - packed
            if let array = self.\(field.name), !array.isEmpty {
                var packedData = Data()
                for item in array {
                    packedData.append(contentsOf: encodeVarint(item))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .bool:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[Bool]>) - packed
            if let array = self.\(field.name), !array.isEmpty {
                var packedData = Data()
                for item in array {
                    packedData.append(contentsOf: encodeVarint(item ? 1 : 0))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .double:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[Double]>) - packed
            if let array = self.\(field.name), !array.isEmpty {
                var packedData = Data()
                for item in array {
                    let bits = item.bitPattern
                    packedData.append(UInt8(truncatingIfNeeded: bits))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 8))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 16))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 24))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 32))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 40))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 48))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 56))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .float:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[Float]>) - packed
            if let array = self.\(field.name), !array.isEmpty {
                var packedData = Data()
                for item in array {
                    let bits = item.bitPattern
                    packedData.append(UInt8(truncatingIfNeeded: bits))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 8))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 16))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 24))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        // Length-delimited types - unpacked
        case .string:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[String]>) - unpacked
            if let array = self.\(field.name) {
                for item in array {
                    data.append(contentsOf: encodeVarint(\(tag)))
                    let stringData = item.data(using: .utf8)!
                    data.append(contentsOf: encodeVarint(UInt64(stringData.count)))
                    data.append(stringData)
                }
            }
            """
        case .data:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<[Data]>) - unpacked
            if let array = self.\(field.name) {
                for item in array {
                    data.append(contentsOf: encodeVarint(\(tag)))
                    data.append(contentsOf: encodeVarint(UInt64(item.count)))
                    data.append(item)
                }
            }
            """
        }
    }

    private static func generateArraySerialize(field: FieldInfo, fieldNumber: Int) -> String {
        let typeInfo = field.typeInfo

        // Arrays must have element type info
        guard let elementTypeBox = typeInfo.arrayElementType else {
            // Fallback: should not happen if type analysis is correct
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Array) - fallback
            for item in self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                let itemData = try encodeItem(item)
                data.append(contentsOf: encodeVarint(UInt64(itemData.count)))
                data.append(itemData)
            }
            """
        }

        let elementType = elementTypeBox.value

        // Check if element type is primitive
        guard case .primitive(let primitiveType) = elementType.category else {
            // Custom types: unpacked repeated (each element has tag + length + data)
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) ([\(elementType.baseType)])
            for item in self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                let nested = try item.toProtobuf()
                data.append(contentsOf: encodeVarint(UInt64(nested.count)))
                data.append(nested)
            }
            """
        }

        // Primitive types: use packed repeated (Proto3 default)
        switch primitiveType {
        // Varint types - packed
        case .int32:
            let tag = (fieldNumber << 3) | 2  // Length-delimited for packed
            return """
            // Field \(fieldNumber): \(field.name) ([Int32]) - packed
            if !self.\(field.name).isEmpty {
                var packedData = Data()
                for item in self.\(field.name) {
                    packedData.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(item))))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .int64:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) ([Int64]) - packed
            if !self.\(field.name).isEmpty {
                var packedData = Data()
                for item in self.\(field.name) {
                    packedData.append(contentsOf: encodeVarint(UInt64(bitPattern: item)))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .uint32:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) ([UInt32]) - packed
            if !self.\(field.name).isEmpty {
                var packedData = Data()
                for item in self.\(field.name) {
                    packedData.append(contentsOf: encodeVarint(UInt64(item)))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .uint64:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) ([UInt64]) - packed
            if !self.\(field.name).isEmpty {
                var packedData = Data()
                for item in self.\(field.name) {
                    packedData.append(contentsOf: encodeVarint(item))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """
        case .bool:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) ([Bool]) - packed
            if !self.\(field.name).isEmpty {
                var packedData = Data()
                for item in self.\(field.name) {
                    packedData.append(contentsOf: encodeVarint(item ? 1 : 0))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """

        // Fixed 64-bit - packed
        case .double:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) ([Double]) - packed
            if !self.\(field.name).isEmpty {
                var packedData = Data()
                for item in self.\(field.name) {
                    let bits = item.bitPattern
                    packedData.append(UInt8(truncatingIfNeeded: bits))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 8))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 16))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 24))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 32))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 40))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 48))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 56))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """

        // Fixed 32-bit - packed
        case .float:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) ([Float]) - packed
            if !self.\(field.name).isEmpty {
                var packedData = Data()
                for item in self.\(field.name) {
                    let bits = item.bitPattern
                    packedData.append(UInt8(truncatingIfNeeded: bits))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 8))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 16))
                    packedData.append(UInt8(truncatingIfNeeded: bits >> 24))
                }
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
                data.append(packedData)
            }
            """

        // Length-delimited types - unpacked (each element has tag + length + data)
        case .string:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) ([String]) - unpacked
            for item in self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                let stringData = item.data(using: .utf8)!
                data.append(contentsOf: encodeVarint(UInt64(stringData.count)))
                data.append(stringData)
            }
            """
        case .data:
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) ([Data]) - unpacked
            for item in self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(item.count)))
                data.append(item)
            }
            """
        }
    }

    private static func generateOptionalSerialize(field: FieldInfo, fieldNumber: Int) -> String {
        let typeInfo = field.typeInfo

        // Get the wire type for the wrapped type
        guard case .primitive(let primitiveType) = typeInfo.category else {
            // Custom types: use length-delimited (wire type 2)
            let tag = (fieldNumber << 3) | 2
            return """
            // Field \(fieldNumber): \(field.name) (Optional<\(typeInfo.baseType)>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                let nested = try value.toProtobuf()
                data.append(contentsOf: encodeVarint(UInt64(nested.count)))
                data.append(nested)
            }
            """
        }

        // Primitive types: use correct wire type
        switch primitiveType {
        case .int32:
            let tag = (fieldNumber << 3) | 0  // Varint
            return """
            // Field \(fieldNumber): \(field.name) (Optional<Int32>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
            }
            """
        case .int64:
            let tag = (fieldNumber << 3) | 0  // Varint
            return """
            // Field \(fieldNumber): \(field.name) (Optional<Int64>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(bitPattern: value)))
            }
            """
        case .uint32:
            let tag = (fieldNumber << 3) | 0  // Varint
            return """
            // Field \(fieldNumber): \(field.name) (Optional<UInt32>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(value)))
            }
            """
        case .uint64:
            let tag = (fieldNumber << 3) | 0  // Varint
            return """
            // Field \(fieldNumber): \(field.name) (Optional<UInt64>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(value))
            }
            """
        case .bool:
            let tag = (fieldNumber << 3) | 0  // Varint
            return """
            // Field \(fieldNumber): \(field.name) (Optional<Bool>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(value ? 1 : 0))
            }
            """
        case .string:
            let tag = (fieldNumber << 3) | 2  // Length-delimited
            return """
            // Field \(fieldNumber): \(field.name) (Optional<String>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                let stringData = value.data(using: .utf8)!
                data.append(contentsOf: encodeVarint(UInt64(stringData.count)))
                data.append(stringData)
            }
            """
        case .data:
            let tag = (fieldNumber << 3) | 2  // Length-delimited
            return """
            // Field \(fieldNumber): \(field.name) (Optional<Data>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                data.append(contentsOf: encodeVarint(UInt64(value.count)))
                data.append(value)
            }
            """
        case .double:
            let tag = (fieldNumber << 3) | 1  // 64-bit fixed
            return """
            // Field \(fieldNumber): \(field.name) (Optional<Double>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                let bits = value.bitPattern
                data.append(UInt8(truncatingIfNeeded: bits))
                data.append(UInt8(truncatingIfNeeded: bits >> 8))
                data.append(UInt8(truncatingIfNeeded: bits >> 16))
                data.append(UInt8(truncatingIfNeeded: bits >> 24))
                data.append(UInt8(truncatingIfNeeded: bits >> 32))
                data.append(UInt8(truncatingIfNeeded: bits >> 40))
                data.append(UInt8(truncatingIfNeeded: bits >> 48))
                data.append(UInt8(truncatingIfNeeded: bits >> 56))
            }
            """
        case .float:
            let tag = (fieldNumber << 3) | 5  // 32-bit fixed
            return """
            // Field \(fieldNumber): \(field.name) (Optional<Float>)
            if let value = self.\(field.name) {
                data.append(contentsOf: encodeVarint(\(tag)))
                let bits = value.bitPattern
                data.append(UInt8(truncatingIfNeeded: bits))
                data.append(UInt8(truncatingIfNeeded: bits >> 8))
                data.append(UInt8(truncatingIfNeeded: bits >> 16))
                data.append(UInt8(truncatingIfNeeded: bits >> 24))
            }
            """
        }
    }

    private static func getWireType(for type: String) -> Int {
        switch type {
        case "Int32", "Int64", "UInt32", "UInt64", "Bool":
            return 0 // Varint
        case "Double":
            return 1 // 64-bit
        case "Float":
            return 5 // 32-bit
        default:
            return 2 // Length-delimited
        }
    }

    private static func generateExtractFieldCase(field: FieldInfo) -> String {
        let typeInfo = field.typeInfo

        // Arrays and custom types are not supported in FoundationDB tuples
        if typeInfo.isArray {
            return "case \"\(field.name)\": return []  // Arrays not supported in tuples"
        }

        if case .custom = typeInfo.category {
            return "case \"\(field.name)\": return []  // Custom types not supported directly; use nested path like \"\(field.name).fieldName\""
        }

        // Primitive types that conform to TupleElement
        if case .primitive(let primitiveType) = typeInfo.category {
            // Data fields are not supported in tuples (binary data cannot be used in indexes)
            if primitiveType == .data {
                return "case \"\(field.name)\": return []  // Data fields not supported in tuples"
            }

            // Handle optionals
            if typeInfo.isOptional {
                switch primitiveType {
                case .int32:
                    return "case \"\(field.name)\": return self.\(field.name).map { [Int64($0)] } ?? []"
                case .uint32:
                    return "case \"\(field.name)\": return self.\(field.name).map { [Int64($0)] } ?? []"
                case .int64, .uint64, .bool, .string, .double, .float:
                    return "case \"\(field.name)\": return self.\(field.name).map { [$0] } ?? []"
                case .data:
                    return "case \"\(field.name)\": return []  // Data fields not supported in tuples"
                }
            } else {
                // Non-optional primitives - convert Int32/UInt32 to Int64 for TupleElement conformance
                switch primitiveType {
                case .int32:
                    return "case \"\(field.name)\": return [Int64(self.\(field.name))]"
                case .uint32:
                    return "case \"\(field.name)\": return [Int64(self.\(field.name))]"
                case .int64, .uint64, .bool, .string, .double, .float:
                    return "case \"\(field.name)\": return [self.\(field.name)]"
                case .data:
                    return "case \"\(field.name)\": return []  // Data fields not supported in tuples"
                }
            }
        }

        // Fallback (should not reach here)
        return "case \"\(field.name)\": return []"
    }

    /// Generate switch cases for nested field access on custom type fields
    private static func generateNestedFieldHandling(fields: [FieldInfo]) -> String {
        let customTypeFields = fields.filter { field in
            let typeInfo = field.typeInfo
            // Only non-array custom types support nested access
            if case .custom = typeInfo.category {
                return !typeInfo.isArray
            }
            return false
        }

        if customTypeFields.isEmpty {
            return ""
        }

        return customTypeFields.map { field in
            let typeInfo = field.typeInfo
            if typeInfo.isOptional {
                // Optional custom type: unwrap and delegate
                return """
                case "\(field.name)":
                    guard let nested = self.\(field.name) else { return [] }
                    return nested.extractField(remainingPath)
                """
            } else {
                // Required custom type: delegate directly
                return """
                case "\(field.name)":
                    return self.\(field.name).extractField(remainingPath)
                """
            }
        }.joined(separator: "\n                ")
    }

    // MARK: - Type Analysis

    /// Analyze a type string and return detailed type information
    private static func analyzeType(_ typeString: String) -> TypeInfo {
        var workingType = typeString.trimmingCharacters(in: .whitespaces)
        var isOptional = false
        var isArray = false
        var arrayElementType: TypeInfo? = nil

        // Detect Optional: "T?" or "Optional<T>"
        if workingType.hasSuffix("?") {
            isOptional = true
            workingType = String(workingType.dropLast())
        } else if workingType.hasPrefix("Optional<") && workingType.hasSuffix(">") {
            isOptional = true
            let innerStart = workingType.index(workingType.startIndex, offsetBy: 9)
            let innerEnd = workingType.index(before: workingType.endIndex)
            workingType = String(workingType[innerStart..<innerEnd])
        }

        // Detect Array: "[T]" or "Array<T>"
        if workingType.hasPrefix("[") && workingType.hasSuffix("]") {
            isArray = true
            let innerStart = workingType.index(after: workingType.startIndex)
            let innerEnd = workingType.index(before: workingType.endIndex)
            let elementTypeString = String(workingType[innerStart..<innerEnd])
            workingType = elementTypeString
            // Recursively analyze element type
            arrayElementType = analyzeType(elementTypeString)
        } else if workingType.hasPrefix("Array<") && workingType.hasSuffix(">") {
            isArray = true
            let innerStart = workingType.index(workingType.startIndex, offsetBy: 6)
            let innerEnd = workingType.index(before: workingType.endIndex)
            let elementTypeString = String(workingType[innerStart..<innerEnd])
            workingType = elementTypeString
            // Recursively analyze element type
            arrayElementType = analyzeType(elementTypeString)
        }

        // Classify the base type
        let category = classifyType(workingType)

        return TypeInfo(
            baseType: workingType,
            isOptional: isOptional,
            isArray: isArray,
            category: category,
            arrayElementType: arrayElementType.map { TypeInfoBox($0) }
        )
    }

    /// Classify a type as primitive or custom
    private static func classifyType(_ type: String) -> TypeCategory {
        switch type {
        case "Int32": return .primitive(.int32)
        case "Int64": return .primitive(.int64)
        case "UInt32": return .primitive(.uint32)
        case "UInt64": return .primitive(.uint64)
        case "Bool": return .primitive(.bool)
        case "String": return .primitive(.string)
        case "Data": return .primitive(.data)
        case "Double": return .primitive(.double)
        case "Float": return .primitive(.float)
        default: return .custom
        }
    }

    private static func generateDecodeSwitch(fields: [FieldInfo]) -> String {
        return fields.enumerated().map { index, field in
            let fieldNumber = index + 1
            return generateDecodeCase(field: field, fieldNumber: fieldNumber)
        }.joined(separator: "\n                    ")
    }

    /// Generate validation code for required (non-optional custom type) fields
    private static func generateRequiredFieldValidation(fields: [FieldInfo]) -> String {
        // Filter for required custom type fields
        let requiredCustomFields = fields.filter { field in
            let typeInfo = field.typeInfo
            // Required if: custom type AND not optional AND not array
            if case .custom = typeInfo.category {
                return !typeInfo.isOptional && !typeInfo.isArray
            }
            return false
        }

        if requiredCustomFields.isEmpty {
            return ""
        }

        // Generate guard let statements for each required field
        return requiredCustomFields.map { field in
            """
            guard let \(field.name) = \(field.name) else {
                    throw RecordLayerError.serializationFailed("Required field '\(field.name)' is missing")
                }
            """
        }.joined(separator: "\n                ")
    }

    // MARK: - Deserialization Helpers

    private static func generatePrimitiveDecode(field: FieldInfo, fieldNumber: Int, primitiveType: PrimitiveType) -> String {
        let typeInfo = field.typeInfo
        let isOptional = typeInfo.isOptional

        switch primitiveType {
        case .int32:
            if isOptional {
                return """
                case \(fieldNumber): // \(field.name) (Int32?)
                    \(field.name) = Int32(bitPattern: UInt32(truncatingIfNeeded: try decodeVarint(data, offset: &offset)))
                """
            } else {
                return """
                case \(fieldNumber): // \(field.name) (Int32)
                    \(field.name) = Int32(bitPattern: UInt32(truncatingIfNeeded: try decodeVarint(data, offset: &offset)))
                """
            }
        case .int64:
            if isOptional {
                return """
                case \(fieldNumber): // \(field.name) (Int64?)
                    \(field.name) = Int64(bitPattern: try decodeVarint(data, offset: &offset))
                """
            } else {
                return """
                case \(fieldNumber): // \(field.name) (Int64)
                    \(field.name) = Int64(bitPattern: try decodeVarint(data, offset: &offset))
                """
            }
        case .uint32:
            if isOptional {
                return """
                case \(fieldNumber): // \(field.name) (UInt32?)
                    \(field.name) = UInt32(truncatingIfNeeded: try decodeVarint(data, offset: &offset))
                """
            } else {
                return """
                case \(fieldNumber): // \(field.name) (UInt32)
                    \(field.name) = UInt32(truncatingIfNeeded: try decodeVarint(data, offset: &offset))
                """
            }
        case .uint64:
            if isOptional {
                return """
                case \(fieldNumber): // \(field.name) (UInt64?)
                    \(field.name) = try decodeVarint(data, offset: &offset)
                """
            } else {
                return """
                case \(fieldNumber): // \(field.name) (UInt64)
                    \(field.name) = try decodeVarint(data, offset: &offset)
                """
            }
        case .bool:
            if isOptional {
                return """
                case \(fieldNumber): // \(field.name) (Bool?)
                    \(field.name) = try decodeVarint(data, offset: &offset) != 0
                """
            } else {
                return """
                case \(fieldNumber): // \(field.name) (Bool)
                    \(field.name) = try decodeVarint(data, offset: &offset) != 0
                """
            }
        case .string:
            return """
            case \(fieldNumber): // \(field.name) (String)
                let length = try decodeVarint(data, offset: &offset)
                let endOffset = offset + Int(length)
                guard endOffset <= data.count else {
                    throw RecordLayerError.serializationFailed("String length exceeds data bounds")
                }
                \(field.name) = String(data: Data(data[offset..<endOffset]), encoding: .utf8) ?? ""
                offset = endOffset
            """
        case .data:
            return """
            case \(fieldNumber): // \(field.name) (Data)
                let length = try decodeVarint(data, offset: &offset)
                let endOffset = offset + Int(length)
                guard endOffset <= data.count else {
                    throw RecordLayerError.serializationFailed("Data length exceeds data bounds")
                }
                \(field.name) = Data(data[offset..<endOffset])
                offset = endOffset
            """
        case .double:
            if isOptional {
                return """
                case \(fieldNumber): // \(field.name) (Double?)
                    guard offset + 8 <= data.count else {
                        throw RecordLayerError.serializationFailed("Not enough data for Double")
                    }
                    let byte0 = UInt64(data[offset])
                    let byte1 = UInt64(data[offset + 1])
                    let byte2 = UInt64(data[offset + 2])
                    let byte3 = UInt64(data[offset + 3])
                    let byte4 = UInt64(data[offset + 4])
                    let byte5 = UInt64(data[offset + 5])
                    let byte6 = UInt64(data[offset + 6])
                    let byte7 = UInt64(data[offset + 7])
                    let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24) | (byte4 << 32) | (byte5 << 40) | (byte6 << 48) | (byte7 << 56)
                    \(field.name) = Double(bitPattern: bits)
                    offset += 8
                """
            } else {
                return """
                case \(fieldNumber): // \(field.name) (Double)
                    guard offset + 8 <= data.count else {
                        throw RecordLayerError.serializationFailed("Not enough data for Double")
                    }
                    let byte0 = UInt64(data[offset])
                    let byte1 = UInt64(data[offset + 1])
                    let byte2 = UInt64(data[offset + 2])
                    let byte3 = UInt64(data[offset + 3])
                    let byte4 = UInt64(data[offset + 4])
                    let byte5 = UInt64(data[offset + 5])
                    let byte6 = UInt64(data[offset + 6])
                    let byte7 = UInt64(data[offset + 7])
                    let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24) | (byte4 << 32) | (byte5 << 40) | (byte6 << 48) | (byte7 << 56)
                    \(field.name) = Double(bitPattern: bits)
                    offset += 8
                """
            }
        case .float:
            if isOptional {
                return """
                case \(fieldNumber): // \(field.name) (Float?)
                    guard offset + 4 <= data.count else {
                        throw RecordLayerError.serializationFailed("Not enough data for Float")
                    }
                    let byte0 = UInt32(data[offset])
                    let byte1 = UInt32(data[offset + 1])
                    let byte2 = UInt32(data[offset + 2])
                    let byte3 = UInt32(data[offset + 3])
                    let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
                    \(field.name) = Float(bitPattern: bits)
                    offset += 4
                """
            } else {
                return """
                case \(fieldNumber): // \(field.name) (Float)
                    guard offset + 4 <= data.count else {
                        throw RecordLayerError.serializationFailed("Not enough data for Float")
                    }
                    let byte0 = UInt32(data[offset])
                    let byte1 = UInt32(data[offset + 1])
                    let byte2 = UInt32(data[offset + 2])
                    let byte3 = UInt32(data[offset + 3])
                    let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
                    \(field.name) = Float(bitPattern: bits)
                    offset += 4
                """
            }
        }
    }

    private static func generatePrimitiveArrayDecode(field: FieldInfo, fieldNumber: Int, primitiveType: PrimitiveType) -> String {
        // Support both packed (wire type 2) and unpacked (original wire type) for backward compatibility
        switch primitiveType {
        // Varint types
        case .int32:
            return """
            case \(fieldNumber): // \(field.name) ([Int32])
                if wireType == 2 {
                    // Packed repeated
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name).append(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name).append(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
                }
            """
        case .int64:
            return """
            case \(fieldNumber): // \(field.name) ([Int64])
                if wireType == 2 {
                    // Packed repeated
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name).append(Int64(bitPattern: value))
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name).append(Int64(bitPattern: value))
                }
            """
        case .uint32:
            return """
            case \(fieldNumber): // \(field.name) ([UInt32])
                if wireType == 2 {
                    // Packed repeated
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name).append(UInt32(truncatingIfNeeded: value))
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name).append(UInt32(truncatingIfNeeded: value))
                }
            """
        case .uint64:
            return """
            case \(fieldNumber): // \(field.name) ([UInt64])
                if wireType == 2 {
                    // Packed repeated
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name).append(value)
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name).append(value)
                }
            """
        case .bool:
            return """
            case \(fieldNumber): // \(field.name) ([Bool])
                if wireType == 2 {
                    // Packed repeated
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name).append(value != 0)
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name).append(value != 0)
                }
            """

        // Fixed 64-bit types
        case .double:
            return """
            case \(fieldNumber): // \(field.name) ([Double])
                if wireType == 2 {
                    // Packed repeated
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        guard offset + 8 <= endOffset else {
                            throw RecordLayerError.serializationFailed("Not enough data for Double array element")
                        }
                        let byte0 = UInt64(data[offset])
                        let byte1 = UInt64(data[offset + 1])
                        let byte2 = UInt64(data[offset + 2])
                        let byte3 = UInt64(data[offset + 3])
                        let byte4 = UInt64(data[offset + 4])
                        let byte5 = UInt64(data[offset + 5])
                        let byte6 = UInt64(data[offset + 6])
                        let byte7 = UInt64(data[offset + 7])
                        let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24) | (byte4 << 32) | (byte5 << 40) | (byte6 << 48) | (byte7 << 56)
                        \(field.name).append(Double(bitPattern: bits))
                        offset += 8
                    }
                } else if wireType == 1 {
                    // Unpacked (backward compatibility)
                    guard offset + 8 <= data.count else {
                        throw RecordLayerError.serializationFailed("Not enough data for Double array element")
                    }
                    let byte0 = UInt64(data[offset])
                    let byte1 = UInt64(data[offset + 1])
                    let byte2 = UInt64(data[offset + 2])
                    let byte3 = UInt64(data[offset + 3])
                    let byte4 = UInt64(data[offset + 4])
                    let byte5 = UInt64(data[offset + 5])
                    let byte6 = UInt64(data[offset + 6])
                    let byte7 = UInt64(data[offset + 7])
                    let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24) | (byte4 << 32) | (byte5 << 40) | (byte6 << 48) | (byte7 << 56)
                    \(field.name).append(Double(bitPattern: bits))
                    offset += 8
                }
            """

        // Fixed 32-bit types
        case .float:
            return """
            case \(fieldNumber): // \(field.name) ([Float])
                if wireType == 2 {
                    // Packed repeated
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        guard offset + 4 <= endOffset else {
                            throw RecordLayerError.serializationFailed("Not enough data for Float array element")
                        }
                        let byte0 = UInt32(data[offset])
                        let byte1 = UInt32(data[offset + 1])
                        let byte2 = UInt32(data[offset + 2])
                        let byte3 = UInt32(data[offset + 3])
                        let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
                        \(field.name).append(Float(bitPattern: bits))
                        offset += 4
                    }
                } else if wireType == 5 {
                    // Unpacked (backward compatibility)
                    guard offset + 4 <= data.count else {
                        throw RecordLayerError.serializationFailed("Not enough data for Float array element")
                    }
                    let byte0 = UInt32(data[offset])
                    let byte1 = UInt32(data[offset + 1])
                    let byte2 = UInt32(data[offset + 2])
                    let byte3 = UInt32(data[offset + 3])
                    let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
                    \(field.name).append(Float(bitPattern: bits))
                    offset += 4
                }
            """

        // Length-delimited types (always unpacked)
        case .string:
            return """
            case \(fieldNumber): // \(field.name) ([String])
                let length = try decodeVarint(data, offset: &offset)
                let endOffset = offset + Int(length)
                guard endOffset <= data.count else {
                    throw RecordLayerError.serializationFailed("Array element length exceeds data bounds")
                }
                let itemData = Data(data[offset..<endOffset])
                let item = String(data: itemData, encoding: .utf8) ?? ""
                \(field.name).append(item)
                offset = endOffset
            """
        case .data:
            return """
            case \(fieldNumber): // \(field.name) ([Data])
                let length = try decodeVarint(data, offset: &offset)
                let endOffset = offset + Int(length)
                guard endOffset <= data.count else {
                    throw RecordLayerError.serializationFailed("Array element length exceeds data bounds")
                }
                let itemData = Data(data[offset..<endOffset])
                \(field.name).append(itemData)
                offset = endOffset
            """
        }
    }

    private static func generateCustomDecode(field: FieldInfo, fieldNumber: Int) -> String {
        let typeInfo = field.typeInfo

        return """
        case \(fieldNumber): // \(field.name) (\(typeInfo.baseType))
            let length = try decodeVarint(data, offset: &offset)
            let endOffset = offset + Int(length)
            guard endOffset <= data.count else {
                throw RecordLayerError.serializationFailed("Custom type field length exceeds data bounds")
            }
            let fieldData = Data(data[offset..<endOffset])
            \(field.name) = try \(typeInfo.baseType).fromProtobuf(fieldData)
            offset = endOffset
        """
    }

    private static func generateCustomArrayDecode(field: FieldInfo, fieldNumber: Int) -> String {
        let typeInfo = field.typeInfo
        let elementType = typeInfo.arrayElementType?.value.baseType ?? typeInfo.baseType

        return """
        case \(fieldNumber): // \(field.name) ([\(elementType)])
            let length = try decodeVarint(data, offset: &offset)
            let endOffset = offset + Int(length)
            guard endOffset <= data.count else {
                throw RecordLayerError.serializationFailed("Custom array element length exceeds data bounds")
            }
            let itemData = Data(data[offset..<endOffset])
            let item = try \(elementType).fromProtobuf(itemData)
            \(field.name).append(item)
            offset = endOffset
        """
    }

    private static func generateOptionalArrayDecode(field: FieldInfo, fieldNumber: Int, primitiveType: PrimitiveType) -> String {
        // For optional arrays [T]?, we need to initialize the array if it's nil before appending
        // Support both packed (wire type 2) and unpacked (original wire type) for backward compatibility
        let initCheck = """
        if \(field.name) == nil {
                    \(field.name) = []
                }
        """

        switch primitiveType {
        // Varint types
        case .int32:
            return """
            case \(fieldNumber): // \(field.name) ([Int32]?)
                if wireType == 2 {
                    // Packed repeated
                    \(initCheck)
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name)!.append(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    \(initCheck)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name)!.append(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
                }
            """
        case .int64:
            return """
            case \(fieldNumber): // \(field.name) ([Int64]?)
                if wireType == 2 {
                    // Packed repeated
                    \(initCheck)
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name)!.append(Int64(bitPattern: value))
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    \(initCheck)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name)!.append(Int64(bitPattern: value))
                }
            """
        case .uint32:
            return """
            case \(fieldNumber): // \(field.name) ([UInt32]?)
                if wireType == 2 {
                    // Packed repeated
                    \(initCheck)
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name)!.append(UInt32(truncatingIfNeeded: value))
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    \(initCheck)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name)!.append(UInt32(truncatingIfNeeded: value))
                }
            """
        case .uint64:
            return """
            case \(fieldNumber): // \(field.name) ([UInt64]?)
                if wireType == 2 {
                    // Packed repeated
                    \(initCheck)
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name)!.append(value)
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    \(initCheck)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name)!.append(value)
                }
            """
        case .bool:
            return """
            case \(fieldNumber): // \(field.name) ([Bool]?)
                if wireType == 2 {
                    // Packed repeated
                    \(initCheck)
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        let value = try decodeVarint(data, offset: &offset)
                        \(field.name)!.append(value != 0)
                    }
                } else if wireType == 0 {
                    // Unpacked (backward compatibility)
                    \(initCheck)
                    let value = try decodeVarint(data, offset: &offset)
                    \(field.name)!.append(value != 0)
                }
            """

        // Fixed 64-bit types
        case .double:
            return """
            case \(fieldNumber): // \(field.name) ([Double]?)
                if wireType == 2 {
                    // Packed repeated
                    \(initCheck)
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        guard offset + 8 <= endOffset else {
                            throw RecordLayerError.serializationFailed("Not enough data for Double array element")
                        }
                        let byte0 = UInt64(data[offset])
                        let byte1 = UInt64(data[offset + 1])
                        let byte2 = UInt64(data[offset + 2])
                        let byte3 = UInt64(data[offset + 3])
                        let byte4 = UInt64(data[offset + 4])
                        let byte5 = UInt64(data[offset + 5])
                        let byte6 = UInt64(data[offset + 6])
                        let byte7 = UInt64(data[offset + 7])
                        let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24) | (byte4 << 32) | (byte5 << 40) | (byte6 << 48) | (byte7 << 56)
                        \(field.name)!.append(Double(bitPattern: bits))
                        offset += 8
                    }
                } else if wireType == 1 {
                    // Unpacked (backward compatibility)
                    \(initCheck)
                    guard offset + 8 <= data.count else {
                        throw RecordLayerError.serializationFailed("Not enough data for Double array element")
                    }
                    let byte0 = UInt64(data[offset])
                    let byte1 = UInt64(data[offset + 1])
                    let byte2 = UInt64(data[offset + 2])
                    let byte3 = UInt64(data[offset + 3])
                    let byte4 = UInt64(data[offset + 4])
                    let byte5 = UInt64(data[offset + 5])
                    let byte6 = UInt64(data[offset + 6])
                    let byte7 = UInt64(data[offset + 7])
                    let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24) | (byte4 << 32) | (byte5 << 40) | (byte6 << 48) | (byte7 << 56)
                    \(field.name)!.append(Double(bitPattern: bits))
                    offset += 8
                }
            """

        // Fixed 32-bit types
        case .float:
            return """
            case \(fieldNumber): // \(field.name) ([Float]?)
                if wireType == 2 {
                    // Packed repeated
                    \(initCheck)
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    while offset < endOffset {
                        guard offset + 4 <= endOffset else {
                            throw RecordLayerError.serializationFailed("Not enough data for Float array element")
                        }
                        let byte0 = UInt32(data[offset])
                        let byte1 = UInt32(data[offset + 1])
                        let byte2 = UInt32(data[offset + 2])
                        let byte3 = UInt32(data[offset + 3])
                        let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
                        \(field.name)!.append(Float(bitPattern: bits))
                        offset += 4
                    }
                } else if wireType == 5 {
                    // Unpacked (backward compatibility)
                    \(initCheck)
                    guard offset + 4 <= data.count else {
                        throw RecordLayerError.serializationFailed("Not enough data for Float array element")
                    }
                    let byte0 = UInt32(data[offset])
                    let byte1 = UInt32(data[offset + 1])
                    let byte2 = UInt32(data[offset + 2])
                    let byte3 = UInt32(data[offset + 3])
                    let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
                    \(field.name)!.append(Float(bitPattern: bits))
                    offset += 4
                }
            """

        // Length-delimited types (always unpacked)
        case .string:
            return """
            case \(fieldNumber): // \(field.name) ([String]?)
                \(initCheck)
                let length = try decodeVarint(data, offset: &offset)
                let endOffset = offset + Int(length)
                guard endOffset <= data.count else {
                    throw RecordLayerError.serializationFailed("Array element length exceeds data bounds")
                }
                let itemData = Data(data[offset..<endOffset])
                let item = String(data: itemData, encoding: .utf8) ?? ""
                \(field.name)!.append(item)
                offset = endOffset
            """
        case .data:
            return """
            case \(fieldNumber): // \(field.name) ([Data]?)
                \(initCheck)
                let length = try decodeVarint(data, offset: &offset)
                let endOffset = offset + Int(length)
                guard endOffset <= data.count else {
                    throw RecordLayerError.serializationFailed("Array element length exceeds data bounds")
                }
                let itemData = Data(data[offset..<endOffset])
                \(field.name)!.append(itemData)
                offset = endOffset
            """
        }
    }

    private static func generateDecodeCase(field: FieldInfo, fieldNumber: Int) -> String {
        let typeInfo = field.typeInfo

        // Check for optional arrays first ([T]?)
        if typeInfo.isOptional && typeInfo.isArray {
            if case .primitive(let primitiveType) = typeInfo.category {
                return generateOptionalArrayDecode(field: field, fieldNumber: fieldNumber, primitiveType: primitiveType)
            } else {
                // Custom type optional array - similar to regular array but with initialization
                let elementType = typeInfo.arrayElementType?.value.baseType ?? typeInfo.baseType
                return """
                case \(fieldNumber): // \(field.name) ([\(elementType)]?)
                    if \(field.name) == nil {
                        \(field.name) = []
                    }
                    let length = try decodeVarint(data, offset: &offset)
                    let endOffset = offset + Int(length)
                    guard endOffset <= data.count else {
                        throw RecordLayerError.serializationFailed("Custom array element length exceeds data bounds")
                    }
                    let itemData = Data(data[offset..<endOffset])
                    let item = try \(elementType).fromProtobuf(itemData)
                    \(field.name)!.append(item)
                    offset = endOffset
                """
            }
        }

        // Dispatch based on type category and modifiers
        if case .primitive(let primitiveType) = typeInfo.category {
            if typeInfo.isArray {
                return generatePrimitiveArrayDecode(field: field, fieldNumber: fieldNumber, primitiveType: primitiveType)
            } else {
                return generatePrimitiveDecode(field: field, fieldNumber: fieldNumber, primitiveType: primitiveType)
            }
        } else {
            // Custom type
            if typeInfo.isArray {
                return generateCustomArrayDecode(field: field, fieldNumber: fieldNumber)
            } else {
                return generateCustomDecode(field: field, fieldNumber: fieldNumber)
            }
        }
    }
}

// MARK: - Supporting Types

struct FieldInfo {
    let name: String
    let type: String           // Original type string (e.g., "Address?", "[String]")
    let typeInfo: TypeInfo     // Parsed type information
    let isPrimaryKey: Bool
    let isTransient: Bool
}

/// Box class for indirect storage of recursive types
final class TypeInfoBox {
    let value: TypeInfo
    init(_ value: TypeInfo) {
        self.value = value
    }
}

struct TypeInfo {
    let baseType: String       // Base type without modifiers (e.g., "Address", "String")
    let isOptional: Bool       // Is Optional<T> or T?
    let isArray: Bool          // Is Array<T> or [T]
    let category: TypeCategory

    var arrayElementType: TypeInfoBox?  // For array types, the element type info (indirect via Box)
}

enum TypeCategory {
    case primitive(PrimitiveType)
    case custom                // Recordable-conforming custom type
}

enum PrimitiveType {
    case int32, int64, uint32, uint64
    case bool
    case string, data
    case double, float
}

struct MacroExpansionErrorMessage: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(_ message: String) {
        self.message = message
        self.diagnosticID = MessageID(domain: "FDBRecordLayerMacros", id: "error")
        self.severity = .error
    }
}

// MARK: - Index Information

/// Information extracted from #Index or #Unique macro calls
struct IndexInfo {
    let fields: [String]      // Field names extracted from KeyPaths
    let isUnique: Bool         // true for #Unique, false for #Index
    let customName: String?    // Custom name from 'name:' parameter
    let typeName: String       // Type name from generic parameter

    /// Generate the index name (e.g., "User_email_unique" or "location_index")
    func indexName() -> String {
        if let customName = customName {
            return customName
        }
        let fieldNames = fields.joined(separator: "_")
        let suffix = isUnique ? "unique" : "index"
        return "\(typeName)_\(fieldNames)_\(suffix)"
    }

    /// Generate the variable name (replace dots with double underscores)
    func variableName() -> String {
        return indexName().replacingOccurrences(of: ".", with: "__")
    }
}
