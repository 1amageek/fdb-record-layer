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

        let members = structDecl.memberBlock.members

        // Extract primary key fields from #PrimaryKey macro
        let primaryKeyFieldNames = try extractPrimaryKeyFields(from: members)

        // Validate: must have at least one primary key
        guard !primaryKeyFieldNames.isEmpty else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: structDecl,
                    message: MacroExpansionErrorMessage("@Recordable struct must have exactly one #PrimaryKey<T>([...]) declaration")
                )
            ])
        }

        // Extract field information
        let fields = try extractFields(from: members, primaryKeyFields: Set(primaryKeyFieldNames), context: context)
        let persistentFields = fields.filter { !$0.isTransient }

        // Generate the extension members
        var results: [DeclSyntax] = []

        // Note: MemberMacro doesn't have access to the 'type' parameter like ExtensionMacro does,
        // so we use the simple name from structDecl. This is acceptable because the fieldName
        // method is added as a member inside the struct itself, where the simple name is sufficient.
        let typeName = structDecl.name.text

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

        let structName = structDecl.name.text  // Simple name for recordType identifier
        let fullTypeName = type.trimmedDescription  // Fully qualified name for extension declaration
        let members = structDecl.memberBlock.members

        // Extract recordName from macro arguments (if provided)
        let recordName = extractRecordName(from: node) ?? structName

        // Extract primary key fields from #PrimaryKey macro
        let primaryKeyFieldNames = try extractPrimaryKeyFields(from: members)

        // Extract field information
        let fields = try extractFields(from: members, primaryKeyFields: Set(primaryKeyFieldNames), context: context)
        let persistentFields = fields.filter { !$0.isTransient }

        // Build primary key FieldInfo array from field names (preserve order from #PrimaryKey)
        let primaryKeyFields = primaryKeyFieldNames.compactMap { pkName in
            fields.first { $0.name == pkName }
        }

        // Detect #Directory metadata
        let directoryMetadata = extractDirectoryMetadata(from: members)

        // Extract index information from #Index/#Unique macro calls
        // Note: We need to check ALL members, including those added by other macros
        // Use declaration.memberBlock.members to get the complete member list
        let allMembers = declaration.memberBlock.members
        var indexInfo = extractIndexInfo(from: allMembers)

        // Extract unique constraints from @Attribute(.unique)
        let attributeUniques = extractUniqueFromAttributes(from: members, typeName: structName)

        // Merge and deduplicate (allows @Attribute(.unique) and #Unique to coexist)
        indexInfo = deduplicateIndexes(indexInfo + attributeUniques)

        // Generate Recordable conformance
        let recordableExtension = try generateRecordableExtension(
            typeName: fullTypeName,  // Use fully qualified name for extension and KeyPaths
            recordName: recordName,
            fields: persistentFields,
            primaryKeyFields: primaryKeyFields,
            directoryMetadata: directoryMetadata,
            indexInfo: indexInfo,
            simpleTypeName: structName  // Pass simple name for recordType
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

    /// Directory metadata extracted from #Directory macro
    private struct DirectoryMetadata {
        enum PathElement {
            case literal(String)
            case keyPath(String)  // field name extracted from KeyPath
        }

        let pathElements: [PathElement]
        let layerType: String  // e.g., "partition", "recordStore"
        let keyPathFields: [String]  // Fields used in KeyPaths

        /// Convert layer name to DirectoryType expression
        var directoryTypeExpression: String {
            switch layerType {
            case "partition":
                return ".partition"
            case "recordStore":
                return ".custom(\"fdb_record_layer\")"
            case "luceneIndex":
                return ".custom(\"lucene_index\")"
            case "timeSeries":
                return ".custom(\"time_series\")"
            case "vectorIndex":
                return ".custom(\"vector_index\")"
            default:
                return ".custom(\"\(layerType)\")"
            }
        }
    }

    /// Extracts #Directory metadata from struct members by looking for #Directory macro calls
    private static func extractDirectoryMetadata(
        from members: MemberBlockItemListSyntax
    ) -> DirectoryMetadata? {
        for member in members {
            // Look for #Directory macro expansion
            guard let macroExpansion = member.decl.as(MacroExpansionDeclSyntax.self),
                  macroExpansion.macroName.text == "Directory" else {
                continue
            }

            // Extract path elements from variadic arguments
            var pathElements: [DirectoryMetadata.PathElement] = []
            var keyPathFields: [String] = []
            var layer = "recordStore"  // Default layer

            // Process all arguments (variadic path elements + optional layer)
            for arg in macroExpansion.arguments {
                // Check if this is the "layer:" labeled argument
                if let label = arg.label, label.text == "layer" {
                    if let memberAccessExpr = arg.expression.as(MemberAccessExprSyntax.self) {
                        layer = memberAccessExpr.declName.baseName.text
                    }
                    continue
                }

                let expr = arg.expression

                // Check if it's a string literal
                if let stringLiteral = expr.as(StringLiteralExprSyntax.self),
                   let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                    pathElements.append(.literal(segment.content.text))
                    continue
                }

                // Check if it's a Field(...) function call
                if let functionCall = expr.as(FunctionCallExprSyntax.self) {
                    // Check if called expression is "Field" (either MemberAccessExprSyntax or DeclReferenceExprSyntax)
                    let isFieldCall: Bool
                    if let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self) {
                        isFieldCall = memberAccess.declName.baseName.text == "Field"
                    } else if let identExpr = functionCall.calledExpression.as(DeclReferenceExprSyntax.self) {
                        isFieldCall = identExpr.baseName.text == "Field"
                    } else {
                        isFieldCall = false
                    }

                    if isFieldCall,
                       let firstArg = functionCall.arguments.first,
                       let keyPathExpr = firstArg.expression.as(KeyPathExprSyntax.self),
                       let component = keyPathExpr.components.first,
                       let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                        let fieldName = property.declName.baseName.text
                        pathElements.append(.keyPath(fieldName))
                        keyPathFields.append(fieldName)
                        continue
                    }
                }
            }

            return DirectoryMetadata(
                pathElements: pathElements,
                layerType: layer,
                keyPathFields: keyPathFields
            )
        }

        return nil
    }

    /// Extracts primary key fields from #PrimaryKey macro call
    ///
    /// Scans the struct body for #PrimaryKey<T>([\.field1, \.field2, ...]) macro expansion
    /// and extracts the field names from the KeyPath array.
    ///
    /// **Example**:
    /// ```swift
    /// #PrimaryKey<User>([\.userID])          → ["userID"]
    /// #PrimaryKey<Hotel>([\.ownerID, \.hotelID]) → ["ownerID", "hotelID"]
    /// ```
    ///
    /// **Validation**:
    /// - Exactly ONE #PrimaryKey macro per struct
    /// - At least ONE field in the KeyPath array
    ///
    /// - Parameter members: Struct members to scan
    /// - Returns: Array of primary key field names (empty if not found)
    /// - Throws: DiagnosticsError if multiple #PrimaryKey macros found
    private static func extractPrimaryKeyFields(
        from members: MemberBlockItemListSyntax
    ) throws -> [String] {
        var foundPrimaryKeys: [(node: MacroExpansionDeclSyntax, fields: [String])] = []

        for member in members {
            // Look for #PrimaryKey macro expansion
            guard let macroExpansion = member.decl.as(MacroExpansionDeclSyntax.self),
                  macroExpansion.macroName.text == "PrimaryKey" else {
                continue
            }

            // Extract the KeyPath array argument (first unlabeled argument)
            guard let arrayArg = macroExpansion.arguments.first else {
                continue
            }

            let fields = extractFieldNamesFromKeyPaths(arrayArg.expression)

            if !fields.isEmpty {
                foundPrimaryKeys.append((macroExpansion, fields))
            }
        }

        // Validate: exactly one #PrimaryKey macro
        if foundPrimaryKeys.count > 1 {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: foundPrimaryKeys[1].node,
                    message: MacroExpansionErrorMessage("Only one #PrimaryKey macro is allowed per struct. Found \(foundPrimaryKeys.count).")
                )
            ])
        }

        return foundPrimaryKeys.first?.fields ?? []
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

    /// Extract unique constraints from @Attribute(.unique) properties
    ///
    /// Scans all properties with @Attribute macro and checks if the `.unique` option is specified.
    /// Creates single-field unique constraints (IndexInfo with isUnique = true).
    ///
    /// **Example**:
    /// ```swift
    /// @Attribute(.unique)
    /// var email: String  // → IndexInfo(fields: ["email"], isUnique: true)
    /// ```
    ///
    /// - Parameters:
    ///   - members: Struct members to scan
    ///   - typeName: Type name for IndexInfo
    /// - Returns: Array of IndexInfo for unique constraints
    private static func extractUniqueFromAttributes(
        from members: MemberBlockItemListSyntax,
        typeName: String
    ) -> [IndexInfo] {
        var uniqueConstraints: [IndexInfo] = []

        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }

            let fieldName = identifier.identifier.text

            // Check for @Attribute macro with .unique option
            let hasUniqueOption = varDecl.attributes.contains { attr in
                guard let attributeSyntax = attr.as(AttributeSyntax.self),
                      attributeSyntax.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Attribute" else {
                    return false
                }

                // Check arguments for .unique option
                guard case let .argumentList(arguments) = attributeSyntax.arguments else {
                    return false
                }

                // Look for unlabeled arguments (variadic options)
                for argument in arguments {
                    if argument.label == nil {
                        // Check if it's .unique member access
                        if let memberAccess = argument.expression.as(MemberAccessExprSyntax.self),
                           memberAccess.declName.baseName.text == "unique" {
                            return true
                        }
                    }
                }

                return false
            }

            if hasUniqueOption {
                uniqueConstraints.append(IndexInfo(
                    fields: [fieldName],
                    isUnique: true,
                    customName: nil,
                    typeName: typeName
                ))
            }
        }

        return uniqueConstraints
    }

    /// Deduplicate index definitions by field combination
    ///
    /// Removes duplicate IndexInfo entries that have the same set of fields.
    /// When duplicates are found, the first occurrence is kept.
    ///
    /// **Deduplication strategy**:
    /// - Same fields → Keep first occurrence (no error)
    /// - Allows @Attribute(.unique) and #Unique<T>([\.field]) to coexist
    ///
    /// **Example**:
    /// ```swift
    /// @Attribute(.unique)
    /// var email: String
    ///
    /// #Unique<User>([\.email])  // Deduplicated, no error
    /// ```
    ///
    /// - Parameter indexes: Array of IndexInfo to deduplicate
    /// - Returns: Deduplicated array (preserving original order)
    private static func deduplicateIndexes(_ indexes: [IndexInfo]) -> [IndexInfo] {
        var seen: Set<Set<String>> = []
        var result: [IndexInfo] = []

        for index in indexes {
            let fieldSet = Set(index.fields)
            if !seen.contains(fieldSet) {
                seen.insert(fieldSet)
                result.append(index)
            }
        }

        return result
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
        primaryKeyFields: Set<String>,
        context: some MacroExpansionContext
    ) throws -> [FieldInfo] {
        var fields: [FieldInfo] = []

        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard let binding = varDecl.bindings.first else { continue }
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }

            let fieldName = identifier.identifier.text

            // Check if this field is in the primary key set
            let isPrimaryKey = primaryKeyFields.contains(fieldName)

            // Check for @Transient
            let isTransient = varDecl.attributes.contains { attr in
                attr.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Transient"
            }

            // Get type
            guard let type = binding.typeAnnotation?.type else { continue }

            let typeString = type.description.trimmingCharacters(in: .whitespaces)
            let typeInfo = analyzeType(typeString)

            // Detect potential enum types (custom types that are not arrays)
            // At macro expansion time, we can't definitively know if a type is an enum,
            // so we mark all custom types as potential enums for runtime checking
            let enumTypeName: String?
            if case .custom = typeInfo.category, !typeInfo.isArray {
                // Extract base type name (without Optional<> wrapper)
                enumTypeName = typeInfo.baseType
            } else {
                enumTypeName = nil
            }

            fields.append(FieldInfo(
                name: fieldName,
                type: typeString,
                typeInfo: typeInfo,
                isPrimaryKey: isPrimaryKey,
                isTransient: isTransient,
                enumTypeName: enumTypeName
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
            // Use string-based initializer to preserve nested field paths (e.g., "address.city")
            // IndexInfo.fields already contains the correct dot-notation for nested fields
            let fieldsLiteral = info.fields.map { "\"\($0)\"" }.joined(separator: ", ")
            let unique = info.isUnique ? "true" : "false"

            return """

                public static var \(varName): IndexDefinition {
                    IndexDefinition(
                        name: "\(indexName)",
                        recordType: "\(typeName)",
                        fields: [\(fieldsLiteral)],
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

    /// Generates openDirectory() and store() methods based on #Directory metadata
    private static func generateDirectoryMethods(
        typeName: String,
        fields: [FieldInfo],
        directoryMetadata: DirectoryMetadata?
    ) -> String {
        guard let metadata = directoryMetadata else {
            // No #Directory macro - generate nothing
            return ""
        }

        var methods: [String] = []

        // Build path array for openDirectory
        let pathArrayElements = metadata.pathElements.map { element in
            switch element {
            case .literal(let value):
                return "\"\(value)\""
            case .keyPath(let fieldName):
                return fieldName
            }
        }.joined(separator: ", ")

        if metadata.keyPathFields.isEmpty {
            // Static path - no parameters
            methods.append("""

            /// Opens or creates the directory for this record type
            ///
            /// - Parameter database: The database to use
            /// - Returns: DirectorySubspace for this record type
            public static func openDirectory(
                database: any DatabaseProtocol
            ) async throws -> DirectorySubspace {
                let directoryLayer = database.makeDirectoryLayer()
                let dir = try await directoryLayer.createOrOpen(
                    path: [\(pathArrayElements)],
                    type: \(metadata.directoryTypeExpression)
                )
                return dir
            }

            /// Creates a RecordStore for this type
            ///
            /// - Parameters:
            ///   - database: The database to use
            ///   - schema: Schema with registered types and indexes
            /// - Returns: RecordStore for this record type
            public static func store(
                database: any DatabaseProtocol,
                schema: Schema
            ) async throws -> RecordStore<\(typeName)> {
                let directory = try await openDirectory(database: database)
                let subspace = directory.subspace
                let statisticsManager = StatisticsManager(database: database, subspace: subspace.subspace(Tuple("stats")))
                return RecordStore(
                    database: database,
                    subspace: subspace,
                    schema: schema,
                    statisticsManager: statisticsManager
                )
            }
            """)
        } else {
            // Dynamic path with KeyPaths - generate parameters
            let parameters = metadata.keyPathFields.map { fieldName -> String in
                if let field = fields.first(where: { $0.name == fieldName }) {
                    return "\(fieldName): \(field.type)"
                } else {
                    return "\(fieldName): String"
                }
            }.joined(separator: ", ")

            let paramDocs = metadata.keyPathFields.map {
                "    ///   - \($0): Partition key value"
            }.joined(separator: "\n")

            methods.append("""

            /// Opens or creates the directory for this record type
            ///
            /// - Parameters:
            \(paramDocs)
            ///   - database: The database to use
            /// - Returns: DirectorySubspace for this record type
            public static func openDirectory(
                \(parameters),
                database: any DatabaseProtocol
            ) async throws -> DirectorySubspace {
                let directoryLayer = database.makeDirectoryLayer()
                let dir = try await directoryLayer.createOrOpen(
                    path: [\(pathArrayElements)],
                    type: \(metadata.directoryTypeExpression)
                )
                return dir
            }

            /// Creates a RecordStore for this type
            ///
            /// - Parameters:
            \(paramDocs)
            ///   - database: The database to use
            ///   - schema: Schema with registered types and indexes
            /// - Returns: RecordStore for this record type
            public static func store(
                \(parameters),
                database: any DatabaseProtocol,
                schema: Schema
            ) async throws -> RecordStore<\(typeName)> {
                let directory = try await openDirectory(\(metadata.keyPathFields.map { "\($0): \($0)" }.joined(separator: ", ")), database: database)
                let subspace = directory.subspace
                let statisticsManager = StatisticsManager(database: database, subspace: subspace.subspace(Tuple("stats")))
                return RecordStore(
                    database: database,
                    subspace: subspace,
                    schema: schema,
                    statisticsManager: statisticsManager
                )
            }
            """)
        }

        return methods.joined(separator: "\n")
    }

    private static func generateRecordableExtension(
        typeName: String,  // Fully qualified name for extension declaration and KeyPaths
        recordName: String,
        fields: [FieldInfo],
        primaryKeyFields: [FieldInfo],
        directoryMetadata: DirectoryMetadata?,
        indexInfo: [IndexInfo],
        simpleTypeName: String  // Simple name for recordType identifier
    ) throws -> ExtensionDeclSyntax {

        let fieldNames = fields.map { "\"\($0.name)\"" }.joined(separator: ", ")
        let primaryKeyNames = primaryKeyFields.map { "\"\($0.name)\"" }.joined(separator: ", ")

        // Generate field numbers (1-indexed, based on declaration order)
        let fieldNumberCases = fields.enumerated().map { index, field in
            let fieldNumber = index + 1
            return "case \"\(field.name)\": return \(fieldNumber)"
        }.joined(separator: "\n            ")

        // Generate toProtobuf
        let serializeFields = fields.enumerated().map { index, field in
            let fieldNumber = index + 1
            return generateSerializeField(field: field, fieldNumber: fieldNumber)
        }.joined(separator: "\n        ")

        // Generate fromProtobuf
        let deserializeFields = fields.enumerated().map { index, field in
            let fieldNumber = index + 1
            return generateDeserializeField(field: field, fieldNumber: fieldNumber)
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

        // Generate openDirectory() and store() methods based on #Directory metadata
        // Use fully qualified typeName for RecordStore<T> return type
        let directoryMethods = generateDirectoryMethods(typeName: typeName, fields: fields, directoryMetadata: directoryMetadata)

        // Generate IndexDefinition static properties and indexDefinitions array
        // Use simple typeName for recordType identifier (must match recordName)
        let (indexStaticProperties, indexDefinitionsProperty) = generateIndexDefinitions(
            typeName: simpleTypeName,
            indexInfo: indexInfo
        )

        // Generate enumMetadata(for:) method for enum fields
        // Use simple typeName for consistency (though currently unused in the function)
        let enumMetadataMethod = generateEnumMetadataMethod(typeName: simpleTypeName, fields: fields)

        // Determine if reconstruction is supported (no non-optional custom type fields)
        let supportsReconstructionValue = hasNonReconstructibleFields(fields: fields, primaryKeyFields: Set(primaryKeyFields.map { $0.name })) ? "false" : "true"

        let extensionCode: DeclSyntax = """
        extension \(raw: typeName): Recordable {
            public static var recordName: String { "\(raw: recordName)" }

            public static var primaryKeyFields: [String] { [\(raw: primaryKeyNames)] }

            public static var allFields: [String] { [\(raw: fieldNames)] }

            public static var supportsReconstruction: Bool { \(raw: supportsReconstructionValue) }
            \(raw: indexStaticProperties)\(raw: indexDefinitionsProperty)\(raw: enumMetadataMethod)

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
                        let endOffset = offset + 8
                        guard endOffset <= data.count else {
                            throw RecordLayerError.serializationFailed("Invalid 64-bit field: offset=\\(offset), dataSize=\\(data.count)")
                        }
                        offset = endOffset
                    case 2: // Length-delimited
                        let length = try decodeVarint(data, offset: &offset)
                        let endOffset = offset + Int(length)
                        guard endOffset <= data.count else {
                            throw RecordLayerError.serializationFailed("Invalid length-delimited field: length=\\(length), remaining=\\(data.count - offset)")
                        }
                        offset = endOffset
                    case 5: // 32-bit
                        let endOffset = offset + 4
                        guard endOffset <= data.count else {
                            throw RecordLayerError.serializationFailed("Invalid 32-bit field: offset=\\(offset), dataSize=\\(data.count)")
                        }
                        offset = endOffset
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

            \(raw: generateReconstructMethodIfSupported(typeName: typeName, fields: fields, primaryKeyFields: primaryKeyFields))
            \(raw: directoryMethods)
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

        case "Int":
            return """
            // Field \(fieldNumber): \(field.name) (Int)
            data.append(contentsOf: encodeVarint(\(tag)))
            data.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(self.\(field.name)))))
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

        case "UInt":
            return """
            // Field \(fieldNumber): \(field.name) (UInt)
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
            // Handle both Int64 and Int (which is stored as Int64 in Protobuf)
            let needsConversion = (typeInfo.baseType == "Int")
            if needsConversion {
                return """
                // Field \(fieldNumber): \(field.name) (Optional<Int>)
                if let value = self.\(field.name) {
                    data.append(contentsOf: encodeVarint(\(tag)))
                    data.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
                }
                """
            } else {
                return """
                // Field \(fieldNumber): \(field.name) (Optional<Int64>)
                if let value = self.\(field.name) {
                    data.append(contentsOf: encodeVarint(\(tag)))
                    data.append(contentsOf: encodeVarint(UInt64(bitPattern: value)))
                }
                """
            }
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
            // Handle both UInt64 and UInt (which is stored as UInt64 in Protobuf)
            let needsConversion = (typeInfo.baseType == "UInt")
            if needsConversion {
                return """
                // Field \(fieldNumber): \(field.name) (Optional<UInt>)
                if let value = self.\(field.name) {
                    data.append(contentsOf: encodeVarint(\(tag)))
                    data.append(contentsOf: encodeVarint(UInt64(value)))
                }
                """
            } else {
                return """
                // Field \(fieldNumber): \(field.name) (Optional<UInt64>)
                if let value = self.\(field.name) {
                    data.append(contentsOf: encodeVarint(\(tag)))
                    data.append(contentsOf: encodeVarint(value))
                }
                """
            }
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
        // Normalize type by removing module prefixes (e.g., "Swift.Int64" -> "Int64", "Foundation.Data" -> "Data")
        let normalizedType = type.split(separator: ".").last.map(String.init) ?? type

        switch normalizedType {
        case "Int32": return .primitive(.int32)
        case "Int64", "Int": return .primitive(.int64)  // Int is treated as Int64
        case "UInt32": return .primitive(.uint32)
        case "UInt64", "UInt": return .primitive(.uint64)  // UInt is treated as UInt64
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
            // Handle both Int64 and Int (which is stored as Int64 in Protobuf)
            let needsConversion = (typeInfo.baseType == "Int")
            if isOptional {
                if needsConversion {
                    return """
                    case \(fieldNumber): // \(field.name) (Int?)
                        \(field.name) = Int(Int64(bitPattern: try decodeVarint(data, offset: &offset)))
                    """
                } else {
                    return """
                    case \(fieldNumber): // \(field.name) (Int64?)
                        \(field.name) = Int64(bitPattern: try decodeVarint(data, offset: &offset))
                    """
                }
            } else {
                if needsConversion {
                    return """
                    case \(fieldNumber): // \(field.name) (Int)
                        \(field.name) = Int(Int64(bitPattern: try decodeVarint(data, offset: &offset)))
                    """
                } else {
                    return """
                    case \(fieldNumber): // \(field.name) (Int64)
                        \(field.name) = Int64(bitPattern: try decodeVarint(data, offset: &offset))
                    """
                }
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
            // Handle both UInt64 and UInt (which is stored as UInt64 in Protobuf)
            let needsConversion = (typeInfo.baseType == "UInt")
            if isOptional {
                if needsConversion {
                    return """
                    case \(fieldNumber): // \(field.name) (UInt?)
                        \(field.name) = UInt(try decodeVarint(data, offset: &offset))
                    """
                } else {
                    return """
                    case \(fieldNumber): // \(field.name) (UInt64?)
                        \(field.name) = try decodeVarint(data, offset: &offset)
                    """
                }
            } else {
                if needsConversion {
                    return """
                    case \(fieldNumber): // \(field.name) (UInt)
                        \(field.name) = UInt(try decodeVarint(data, offset: &offset))
                    """
                } else {
                    return """
                    case \(fieldNumber): // \(field.name) (UInt64)
                        \(field.name) = try decodeVarint(data, offset: &offset)
                    """
                }
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

    /// Generate enumMetadata(for:) method
    ///
    /// This method generates runtime enum detection code using CaseIterable protocol.
    /// For each field with potential enum type, it attempts to cast to CaseIterable
    /// and extract case names.
    ///
    /// **Generated Code Example**:
    /// ```swift
    /// public static func enumMetadata(for fieldName: String) -> Schema.EnumMetadata? {
    ///     switch fieldName {
    ///     case "status":
    ///         if let enumType = ProductStatus.self as? any CaseIterable.Type {
    ///             let cases = enumType.allCases.map { "\($0)" }
    ///             return Schema.EnumMetadata(
    ///                 typeName: "ProductStatus",
    ///                 cases: cases
    ///             )
    ///         }
    ///         return nil
    ///     default:
    ///         return nil
    ///     }
    /// }
    /// ```
    private static func generateEnumMetadataMethod(typeName: String, fields: [FieldInfo]) -> String {
        // Filter fields with potential enum types
        let enumCandidateFields = fields.filter { $0.enumTypeName != nil }

        guard !enumCandidateFields.isEmpty else {
            // No enum fields, return empty default implementation (already provided by protocol extension)
            return ""
        }

        let cases = enumCandidateFields.map { field in
            let enumTypeName = field.enumTypeName!
            return """
            case "\(field.name)":
                    // Attempt to cast \(enumTypeName) to CaseIterable at runtime
                    if let enumType = \(enumTypeName).self as? any CaseIterable.Type {
                        let cases = enumType.allCases.map { "\\($0)" }
                        return Schema.EnumMetadata(
                            typeName: "\(enumTypeName)",
                            cases: cases
                        )
                    }
                    return nil
            """
        }.joined(separator: "\n            ")

        return """

            public static func enumMetadata(for fieldName: String) -> Schema.EnumMetadata? {
                switch fieldName {
                \(cases)
                default:
                    return nil
                }
            }
        """
    }

    /// Generate reconstruct() method for covering index support
    ///
    /// This method generates code to reconstruct a record from covering index key and value.
    /// The reconstruction extracts:
    /// 1. Indexed fields from index key (via index.rootExpression.columnCount)
    /// 2. Primary key from index key (last N elements)
    /// 3. Covering fields from index value (via index.coveringFields)
    ///
    /// **Generated Code Example**:
    /// ```swift
    /// public static func reconstruct(
    ///     indexKey: Tuple,
    ///     indexValue: FDB.Bytes,
    ///     index: Index,
    ///     primaryKeyExpression: KeyExpression
    /// ) throws -> User {
    ///     let rootCount = index.rootExpression.columnCount
    ///     let pkCount = primaryKeyExpression.columnCount
    ///
    ///     // Extract indexed field: city
    ///     guard let city = indexKey[0] as? String else {
    ///         throw RecordLayerError.reconstructionFailed(...)
    ///     }
    ///
    ///     // Extract primary key: userID
    ///     guard let userID = indexKey[rootCount] as? Int64 else {
    ///         throw RecordLayerError.reconstructionFailed(...)
    ///     }
    ///
    ///     // Extract covering fields
    ///     let coveringTuple = try Tuple.unpack(from: indexValue)
    ///     guard let name = coveringTuple[0] as? String,
    ///           let email = coveringTuple[1] as? String else {
    ///         throw RecordLayerError.reconstructionFailed(...)
    ///     }
    ///
    ///     return User(userID: userID, city: city, name: name, email: email)
    /// }
    /// ```
    private static func generateReconstructMethod(
        typeName: String,
        fields: [FieldInfo],
        primaryKeyFields: [FieldInfo]
    ) -> String {
        // Generate field extraction and initialization code
        var fieldExtractions: [String] = []
        var initializationParams: [String] = []

        // Track which fields need to be extracted from index key/value
        // var indexedFieldsMap: [String: String] = [:]  // fieldName -> extraction code (unused)
        var primaryKeyFieldsMap: [String: String] = [:]  // fieldName -> extraction code
        var coveringFieldsMap: [String: String] = [:]  // fieldName -> extraction code

        // Build field extraction code
        for field in fields {
            let fieldName = field.name
            let typeInfo = field.typeInfo

            // Skip transient fields
            if field.isTransient {
                continue
            }

            // Determine extraction strategy based on field role
            if field.isPrimaryKey {
                // Primary key field - extract from index key suffix
                let extractionCode = generateFieldExtraction(
                    field: field,
                    source: "indexKey",
                    indexVar: "pkIndex",
                    isFromCoveringTuple: false
                )
                primaryKeyFieldsMap[fieldName] = extractionCode
                fieldExtractions.append(extractionCode)
            } else if typeInfo.isArray {
                // Array fields - provide default empty arrays (can't be indexed/covered)
                if typeInfo.isOptional {
                    fieldExtractions.append("let \(fieldName): \(field.type) = nil")
                } else {
                    fieldExtractions.append("let \(fieldName): \(field.type) = []")
                }
            } else if case .custom = typeInfo.category {
                // Custom types - cannot be directly in indexes/covering fields
                // Custom types must be nested Recordable types, which cannot be reconstructed
                // without deserialization. Always use nil (will fail at init if required).
                fieldExtractions.append("let \(fieldName): \(typeInfo.baseType)? = nil  // Custom type - cannot reconstruct from index")
            } else {
                // Non-PK non-array field - will be extracted from either index key or covering value
                let extractionCode = generateFieldExtraction(
                    field: field,
                    source: "field value",
                    indexVar: "fieldIndex",
                    isFromCoveringTuple: true
                )
                coveringFieldsMap[fieldName] = extractionCode
            }

            initializationParams.append("\(fieldName): \(fieldName)")
        }

        let initParams = initializationParams.joined(separator: ", ")

        return """

            public static func reconstruct(
                indexKey: Tuple,
                indexValue: [UInt8],
                index: Index,
                primaryKeyExpression: KeyExpression
            ) throws -> Self {
                let rootCount = index.rootExpression.columnCount
                let pkCount = primaryKeyExpression.columnCount

                // Validate index key has enough elements
                guard indexKey.count >= rootCount + pkCount else {
                    throw RecordLayerError.reconstructionFailed(
                        recordType: "\(typeName)",
                        reason: "Index key has \\(indexKey.count) elements, expected at least \\(rootCount + pkCount) (\\(rootCount) indexed + \\(pkCount) primary key)"
                    )
                }

                // Extract primary key fields
                var pkIndex = rootCount
                \(generatePrimaryKeyExtractions(primaryKeyFields: primaryKeyFields))

                // Extract indexed and covering fields
                let coveringElements: [any TupleElement]
                if !indexValue.isEmpty {
                    let coveringTuple = Tuple(try Tuple.unpack(from: indexValue))
                    coveringElements = (0..<coveringTuple.count).compactMap { coveringTuple[$0] }
                } else {
                    coveringElements = []  // Empty for non-covering indexes
                }

                // Map index.rootExpression field names to values
                var indexedFieldValues: [String: any TupleElement] = [:]
                let rootFieldNames = index.rootExpression.fieldNames()
                for (i, fieldName) in rootFieldNames.enumerated() {
                    if i < rootCount, let value = indexKey[i] {
                        indexedFieldValues[fieldName] = value
                    }
                }

                // Map index.coveringFields to values
                var coveringFieldValues: [String: any TupleElement] = [:]
                if let coveringExprs = index.coveringFields {
                    // Extract field names from covering KeyExpressions
                    let coveringFieldNames = coveringExprs.compactMap { expr -> String? in
                        if let fieldExpr = expr as? FieldKeyExpression {
                            return fieldExpr.fieldName
                        }
                        return nil
                    }
                    for (i, fieldName) in coveringFieldNames.enumerated() {
                        if i < coveringElements.count {
                            coveringFieldValues[fieldName] = coveringElements[i]
                        }
                    }
                }

                // Extract array and custom type fields (defaults)
                \(generateArrayAndCustomTypeDefaults(fields: fields, primaryKeyFields: Set(primaryKeyFields.map { $0.name })))

                // Extract all other non-PK fields from index/covering values
                \(generateNonPKFieldExtractions(fields: fields, primaryKeyFields: Set(primaryKeyFields.map { $0.name })))

                return .init(\(initParams))
            }
        """
    }

    /// Generate extraction code for primary key fields
    private static func generatePrimaryKeyExtractions(primaryKeyFields: [FieldInfo]) -> String {
        return primaryKeyFields.map { field in
            let typeInfo = field.typeInfo
            let fieldName = field.name

            // Determine the expected type for casting
            let castType: String
            if case .primitive(let primitiveType) = typeInfo.category {
                switch primitiveType {
                case .int32, .uint32:
                    castType = "Int64"  // Tuple stores as Int64
                case .int64:
                    castType = "Int64"
                case .uint64:
                    castType = "UInt64"
                case .bool:
                    castType = "Bool"
                case .string:
                    castType = "String"
                case .double:
                    castType = "Double"
                case .float:
                    castType = "Float"
                case .data:
                    castType = "FDB.Bytes"
                }
            } else {
                // Custom types not supported in primary keys (should not happen)
                castType = "Any"
            }

            // Generate extraction with type conversion
            let conversionCode: String
            if typeInfo.baseType == "Int32" || typeInfo.baseType == "UInt32" || typeInfo.baseType == "Int" || typeInfo.baseType == "UInt" {
                conversionCode = "\(typeInfo.baseType)(value)"
            } else {
                conversionCode = "value"
            }

            return """
                guard let pk_\(fieldName)_value = indexKey[pkIndex] as? \(castType) else {
                        throw RecordLayerError.reconstructionFailed(
                            recordType: "\(typeInfo.baseType)",
                            reason: "Invalid primary key field '\(fieldName)': expected \(castType) at index \\(pkIndex)"
                        )
                    }
                    let \(fieldName) = \(conversionCode.replacingOccurrences(of: "value", with: "pk_\(fieldName)_value"))
                    pkIndex += 1
            """
        }.joined(separator: "\n                ")
    }

    /// Generate extraction code for non-primary key fields
    private static func generateNonPKFieldExtractions(fields: [FieldInfo], primaryKeyFields: Set<String>) -> String {
        // Filter out transient, PK, array, and custom type fields
        // (arrays and custom types can't be directly indexed or covered)
        let nonPKFields = fields.filter { field in
            if field.isTransient || primaryKeyFields.contains(field.name) || field.typeInfo.isArray {
                return false
            }
            // Also filter out custom types
            switch field.typeInfo.category {
            case .custom:
                return false
            default:
                return true
            }
        }

        return nonPKFields.map { field in
            let typeInfo = field.typeInfo
            let fieldName = field.name

            // Determine the expected type for casting
            let castType: String
            if case .primitive(let primitiveType) = typeInfo.category {
                switch primitiveType {
                case .int32, .uint32:
                    castType = "Int64"
                case .int64:
                    castType = "Int64"
                case .uint64:
                    castType = "UInt64"
                case .bool:
                    castType = "Bool"
                case .string:
                    castType = "String"
                case .double:
                    castType = "Double"
                case .float:
                    castType = "Float"
                case .data:
                    castType = "[UInt8]"  // FDB.Bytes is [UInt8]
                }
            } else {
                // Custom types - nested Recordable
                castType = typeInfo.baseType
            }

            // Generate extraction with fallback
            let conversionCode: String
            if typeInfo.baseType == "Int32" || typeInfo.baseType == "UInt32" || typeInfo.baseType == "Int" || typeInfo.baseType == "UInt" {
                conversionCode = "\(typeInfo.baseType)(value)"
            } else if typeInfo.baseType == "Data" {
                // Convert FDB.Bytes ([UInt8]) to Data
                conversionCode = "Data(value)"
            } else {
                conversionCode = "value"
            }

            // Handle optional vs required fields
            let extractionCode: String
            if typeInfo.isOptional {
                let indexedConversion = conversionCode.replacingOccurrences(of: "value", with: "idx_\(fieldName)_val")
                let coveringConversion = conversionCode.replacingOccurrences(of: "value", with: "cov_\(fieldName)_val")
                extractionCode = """
                    let \(fieldName): \(typeInfo.baseType)? = {
                            if let idx_\(fieldName)_val = indexedFieldValues["\(fieldName)"] as? \(castType) {
                                return \(indexedConversion)
                            } else if let cov_\(fieldName)_val = coveringFieldValues["\(fieldName)"] as? \(castType) {
                                return \(coveringConversion)
                            }
                            return nil
                        }()
                """
            } else {
                let indexedConversion = conversionCode.replacingOccurrences(of: "value", with: "idx_\(fieldName)_val")
                let coveringConversion = conversionCode.replacingOccurrences(of: "value", with: "cov_\(fieldName)_val")
                extractionCode = """
                    let \(fieldName): \(typeInfo.baseType) = {
                            if let idx_\(fieldName)_val = indexedFieldValues["\(fieldName)"] as? \(castType) {
                                return \(indexedConversion)
                            } else if let cov_\(fieldName)_val = coveringFieldValues["\(fieldName)"] as? \(castType) {
                                return \(coveringConversion)
                            }
                            // This should not happen if index is properly configured
                            fatalError("Field '\(fieldName)' not found in indexed or covering fields")
                        }()
                """
            }

            return extractionCode
        }.joined(separator: "\n                ")
    }

    /// Generate reconstruct method if supported, otherwise generate stub that throws
    private static func generateReconstructMethodIfSupported(
        typeName: String,
        fields: [FieldInfo],
        primaryKeyFields: [FieldInfo]
    ) -> String {
        let primaryKeyFieldSet = Set(primaryKeyFields.map { $0.name })

        // Check if record has non-reconstructible fields
        if hasNonReconstructibleFields(fields: fields, primaryKeyFields: primaryKeyFieldSet) {
            // Generate stub that throws immediately
            return """

                public static func reconstruct(
                    indexKey: Tuple,
                    indexValue: [UInt8],
                    index: Index,
                    primaryKeyExpression: KeyExpression
                ) throws -> Self {
                    throw RecordLayerError.reconstructionFailed(
                        recordType: "\(typeName)",
                        reason: "This record type contains required custom type fields and does not support covering index reconstruction. Use regular index scan instead."
                    )
                }
            """
        } else {
            // Generate full reconstruct method
            return generateReconstructMethod(typeName: typeName, fields: fields, primaryKeyFields: primaryKeyFields)
        }
    }

    /// Generate field extraction code (helper for complex cases)
    private static func generateFieldExtraction(
        field: FieldInfo,
        source: String,
        indexVar: String,
        isFromCoveringTuple: Bool
    ) -> String {
        // This is a placeholder for more complex extraction logic if needed
        // Currently, extraction is handled inline in generateReconstructMethod
        return "// Extract \(field.name) from \(source)"
    }

    /// Check if record has non-reconstructible fields
    ///
    /// A field is non-reconstructible if:
    /// - It's a non-optional custom type (nested Recordable)
    /// - (Non-optional arrays are OK because they default to [])
    ///
    /// - Parameters:
    ///   - fields: All fields in the record
    ///   - primaryKeyFields: Set of primary key field names
    /// - Returns: `true` if record has non-reconstructible fields, `false` otherwise
    private static func hasNonReconstructibleFields(fields: [FieldInfo], primaryKeyFields: Set<String>) -> Bool {
        for field in fields {
            // Skip transient and primary key fields
            if field.isTransient || primaryKeyFields.contains(field.name) {
                continue
            }

            // Check for non-optional custom type
            if case .custom = field.typeInfo.category {
                if !field.typeInfo.isOptional {
                    // Non-optional custom type cannot be reconstructed from index
                    return true
                }
            }
        }
        return false
    }

    /// Generate default values for array and custom type fields
    private static func generateArrayAndCustomTypeDefaults(fields: [FieldInfo], primaryKeyFields: Set<String>) -> String {
        let arrayAndCustomFields = fields.filter { field in
            if field.isTransient || primaryKeyFields.contains(field.name) {
                return false
            }
            // Check for array or custom type
            if field.typeInfo.isArray {
                return true
            }
            switch field.typeInfo.category {
            case .custom:
                return true
            default:
                return false
            }
        }

        return arrayAndCustomFields.map { field in
            if field.typeInfo.isArray {
                if field.typeInfo.isOptional {
                    return "let \(field.name): \(field.type) = nil"
                } else {
                    return "let \(field.name): \(field.type) = []"
                }
            } else {  // custom type
                if field.typeInfo.isOptional {
                    return "let \(field.name): \(field.type) = nil  // Custom type - cannot reconstruct from index"
                } else {
                    // Required custom type - throw error instead of crashing
                    // Note: This should not be reached if supportsReconstruction = false is respected
                    let baseTypeName = field.typeInfo.baseType
                    return """
                    // Required custom type - cannot reconstruct from index
                    throw RecordLayerError.reconstructionFailed(
                        recordType: "\\(Self.recordName)",
                        reason: "Field '\(field.name)' is a required custom type (\(baseTypeName)) and cannot be reconstructed from index. This record does not support covering index reconstruction."
                    )
                    """
                }
            }
        }.joined(separator: "\n                ")
    }
}

// MARK: - Supporting Types

struct FieldInfo {
    let name: String
    let type: String           // Original type string (e.g., "Address?", "[String]")
    let typeInfo: TypeInfo     // Parsed type information
    let isPrimaryKey: Bool
    let isTransient: Bool
    let enumTypeName: String?  // Enum type name if field is an enum (e.g., "ProductStatus")
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
    case enumType(String)      // Enum type (type name stored for metadata)
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
