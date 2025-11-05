import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the @Recordable macro
///
/// This macro generates:
/// - Recordable protocol conformance
/// - Static metadata properties (recordTypeName, primaryKeyFields, allFields)
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

        let typeName = structDecl.name.text
        let members = structDecl.memberBlock.members

        // Extract field information
        let fields = try extractFields(from: members, context: context)
        let primaryKeyFields = fields.filter { $0.isPrimaryKey }
        let persistentFields = fields.filter { !$0.isTransient }

        // Generate Recordable conformance
        let recordableExtension = try generateRecordableExtension(
            typeName: typeName,
            fields: persistentFields,
            primaryKeyFields: primaryKeyFields
        )

        return [recordableExtension]
    }

    // MARK: - Helper Methods

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

    private static func generateRecordableExtension(
        typeName: String,
        fields: [FieldInfo],
        primaryKeyFields: [FieldInfo]
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

        let extensionCode: DeclSyntax = """
        extension \(raw: typeName): Recordable {
            public static var recordTypeName: String { "\(raw: typeName)" }

            public static var primaryKeyFields: [String] { [\(raw: primaryKeyNames)] }

            public static var allFields: [String] { [\(raw: fieldNames)] }

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
                    // Handle primitive types
                    var itemData = Data()
                    if let intValue = item as? Int64 {
                        itemData.append(contentsOf: encodeVarint(UInt64(bitPattern: intValue)))
                    } else if let stringValue = item as? String {
                        itemData.append(stringValue.data(using: .utf8) ?? Data())
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
            if field.type.hasPrefix("Array<") {
                return generateArraySerialize(field: field, fieldNumber: fieldNumber)
            } else if field.type.hasPrefix("Optional<") || field.type.hasSuffix("?") {
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

    private static func generateArraySerialize(field: FieldInfo, fieldNumber: Int) -> String {
        let tag = (fieldNumber << 3) | 2 // Length-delimited
        return """
        // Field \(fieldNumber): \(field.name) (Array)
        for item in self.\(field.name) {
            data.append(contentsOf: encodeVarint(\(tag)))
            let itemData = try encodeItem(item)
            data.append(contentsOf: encodeVarint(UInt64(itemData.count)))
            data.append(itemData)
        }
        """
    }

    private static func generateOptionalSerialize(field: FieldInfo, fieldNumber: Int) -> String {
        let tag = (fieldNumber << 3) | 2 // Length-delimited for safety
        return """
        // Field \(fieldNumber): \(field.name) (Optional)
        if let value = self.\(field.name) {
            data.append(contentsOf: encodeVarint(\(tag)))
            let valueData = try encodeValue(value)
            data.append(contentsOf: encodeVarint(UInt64(valueData.count)))
            data.append(valueData)
        }
        """
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
            // Handle optionals
            if typeInfo.isOptional {
                switch primitiveType {
                case .int32:
                    return "case \"\(field.name)\": return self.\(field.name).map { [Int64($0)] } ?? []"
                case .uint32:
                    return "case \"\(field.name)\": return self.\(field.name).map { [Int64($0)] } ?? []"
                case .int64, .uint64, .bool, .string, .data, .double, .float:
                    return "case \"\(field.name)\": return self.\(field.name).map { [$0] } ?? []"
                }
            } else {
                // Non-optional primitives - convert Int32/UInt32 to Int64 for TupleElement conformance
                switch primitiveType {
                case .int32:
                    return "case \"\(field.name)\": return [Int64(self.\(field.name))]"
                case .uint32:
                    return "case \"\(field.name)\": return [Int64(self.\(field.name))]"
                case .int64, .uint64, .bool, .string, .data, .double, .float:
                    return "case \"\(field.name)\": return [self.\(field.name)]"
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
        switch primitiveType {
        case .int32:
            return """
            case \(fieldNumber): // \(field.name) (Int32)
                \(field.name) = Int32(bitPattern: UInt32(truncatingIfNeeded: try decodeVarint(data, offset: &offset)))
            """
        case .int64:
            return """
            case \(fieldNumber): // \(field.name) (Int64)
                \(field.name) = Int64(bitPattern: try decodeVarint(data, offset: &offset))
            """
        case .uint32:
            return """
            case \(fieldNumber): // \(field.name) (UInt32)
                \(field.name) = UInt32(truncatingIfNeeded: try decodeVarint(data, offset: &offset))
            """
        case .uint64:
            return """
            case \(fieldNumber): // \(field.name) (UInt64)
                \(field.name) = try decodeVarint(data, offset: &offset)
            """
        case .bool:
            return """
            case \(fieldNumber): // \(field.name) (Bool)
                \(field.name) = try decodeVarint(data, offset: &offset) != 0
            """
        case .string:
            return """
            case \(fieldNumber): // \(field.name) (String)
                let length = try decodeVarint(data, offset: &offset)
                let endOffset = offset + Int(length)
                guard endOffset <= data.count else {
                    throw RecordLayerError.serializationFailed("String length exceeds data bounds")
                }
                \(field.name) = String(data: data[offset..<endOffset], encoding: .utf8) ?? ""
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
                \(field.name) = data[offset..<endOffset]
                offset = endOffset
            """
        case .double:
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
        case .float:
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

    private static func generatePrimitiveArrayDecode(field: FieldInfo, fieldNumber: Int, primitiveType: PrimitiveType) -> String {
        // Varint types decode directly from the stream
        switch primitiveType {
        case .int32:
            return """
            case \(fieldNumber): // \(field.name) ([Int32])
                let value = try decodeVarint(data, offset: &offset)
                let item = Int32(bitPattern: UInt32(truncatingIfNeeded: value))
                \(field.name).append(item)
            """
        case .int64:
            return """
            case \(fieldNumber): // \(field.name) ([Int64])
                let value = try decodeVarint(data, offset: &offset)
                let item = Int64(bitPattern: value)
                \(field.name).append(item)
            """
        case .uint32:
            return """
            case \(fieldNumber): // \(field.name) ([UInt32])
                let value = try decodeVarint(data, offset: &offset)
                let item = UInt32(truncatingIfNeeded: value)
                \(field.name).append(item)
            """
        case .uint64:
            return """
            case \(fieldNumber): // \(field.name) ([UInt64])
                let value = try decodeVarint(data, offset: &offset)
                \(field.name).append(value)
            """
        case .bool:
            return """
            case \(fieldNumber): // \(field.name) ([Bool])
                let value = try decodeVarint(data, offset: &offset)
                let item = value != 0
                \(field.name).append(item)
            """

        // Length-delimited types
        case .string:
            return """
            case \(fieldNumber): // \(field.name) ([String])
                let length = try decodeVarint(data, offset: &offset)
                let endOffset = offset + Int(length)
                guard endOffset <= data.count else {
                    throw RecordLayerError.serializationFailed("Array element length exceeds data bounds")
                }
                let itemData = data[offset..<endOffset]
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
                let itemData = data[offset..<endOffset]
                \(field.name).append(itemData)
                offset = endOffset
            """

        // Fixed-size types
        case .double:
            return """
            case \(fieldNumber): // \(field.name) ([Double])
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
                let item = Double(bitPattern: bits)
                \(field.name).append(item)
                offset += 8
            """
        case .float:
            return """
            case \(fieldNumber): // \(field.name) ([Float])
                guard offset + 4 <= data.count else {
                    throw RecordLayerError.serializationFailed("Not enough data for Float array element")
                }
                let byte0 = UInt32(data[offset])
                let byte1 = UInt32(data[offset + 1])
                let byte2 = UInt32(data[offset + 2])
                let byte3 = UInt32(data[offset + 3])
                let bits = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
                let item = Float(bitPattern: bits)
                \(field.name).append(item)
                offset += 4
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
            let fieldData = data[offset..<endOffset]
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
            let itemData = data[offset..<endOffset]
            let item = try \(elementType).fromProtobuf(itemData)
            \(field.name).append(item)
            offset = endOffset
        """
    }

    private static func generateDecodeCase(field: FieldInfo, fieldNumber: Int) -> String {
        let typeInfo = field.typeInfo

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
