import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

/// Information for generating type-safe spatial coordinate accessors
///
/// **Purpose**: Eliminates Mirror-based reflection in SpatialIndexMaintainer
/// by generating compile-time KeyPath accessors for each @Spatial property.
///
/// **Example**:
/// ```swift
/// @Spatial(type: .geo(latitude: \.lat, longitude: \.lon))
/// var location: Location
/// ```
/// Generates:
/// ```swift
/// static subscript(spatialField field: String, coordinate: String) -> KeyPath<Self, Double>? {
///     switch (field, coordinate) {
///     case ("location", "latitude"): return \.location.lat
///     case ("location", "longitude"): return \.location.lon
///     default: return nil
///     }
/// }
/// ```
fileprivate struct SpatialAccessorInfo {
    /// Field name with @Spatial attribute (e.g., "location")
    let fieldName: String

    /// Field type name (e.g., "Location")
    let fieldType: String

    /// Coordinate names in order (e.g., ["latitude", "longitude"] or ["x", "y", "z"])
    let coordinateNames: [String]

    /// Relative KeyPath strings from field type (e.g., ["\.latitude", "\.longitude"])
    /// These will be composed with \Self.fieldName to create absolute KeyPaths
    let relativeKeyPathStrings: [String]

    /// Spatial type for validation
    let spatialType: String  // ".geo", ".cartesian", etc.
}

/// Implementation of the @Recordable macro
///
/// This macro generates:
/// - Recordable protocol conformance
/// - Static metadata properties (recordName, primaryKeyFields, allFields)
/// - Protobuf serialization/deserialization methods
/// - Field extraction methods
/// - **Type-safe spatial coordinate accessors** (eliminates Mirror usage)
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

        // Note: extractRangeBoundary is generated in ExtensionMacro, not here
        // Note: CodingKeys generation removed due to Swift macro system restrictions
        // Protobuf encoder will use Recordable.fieldNumber() instead

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

        // Validate that all primary key fields were found
        if primaryKeyFields.count != primaryKeyFieldNames.count {
            let foundNames = Set(primaryKeyFields.map { $0.name })
            let missingFields = primaryKeyFieldNames.filter { !foundNames.contains($0) }

            context.diagnose(
                Diagnostic(
                    node: node,
                    message: RecordableMacroDiagnostic.primaryKeyFieldNotFound(
                        missingFields: missingFields,
                        availableFields: fields.map { $0.name }
                    )
                )
            )
            return []
        }

        // Detect #Directory metadata
        let directoryMetadata = extractDirectoryMetadata(from: members, fields: fields, context: context)

        // Extract index information from #Index/#Unique macro calls
        // Note: We need to check ALL members, including those added by other macros
        // Use declaration.memberBlock.members to get the complete member list
        let allMembers = declaration.memberBlock.members
        var indexInfo = extractIndexInfo(from: allMembers)

        // Extract unique constraints from @Attribute(.unique)
        let attributeUniques = extractUniqueFromAttributes(from: members, typeName: structName)

        // Extract vector/spatial indexes from @Vector/@Spatial attributes
        let (vectorSpatialIndexes, spatialAccessors) = extractVectorSpatialIndexes(from: members, typeName: structName)

        // Merge all indexes
        let allIndexes = indexInfo + attributeUniques + vectorSpatialIndexes

        // Expand Range type indexes (Range<T> → 2 indexes, PartialRange → 1 index)
        let expandedIndexes = expandRangeIndexes(indexes: allIndexes, fields: fields)

        // Deduplicate (allows @Attribute(.unique), #Unique, @Vector, @Spatial to coexist)
        indexInfo = deduplicateIndexes(expandedIndexes)

        // Generate Recordable conformance
        let recordableExtension = try generateRecordableExtension(
            typeName: fullTypeName,  // Use fully qualified name for extension and KeyPaths
            recordName: recordName,
            fields: persistentFields,
            primaryKeyFields: primaryKeyFields,
            directoryMetadata: directoryMetadata,
            indexInfo: indexInfo,
            simpleTypeName: structName,  // Pass simple name for recordType
            spatialAccessors: spatialAccessors  // Type-safe spatial coordinate accessors
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
        from members: MemberBlockItemListSyntax,
        fields: [FieldInfo],
        context: some MacroExpansionContext
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
            var hasInvalidFields = false

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

                    if isFieldCall {
                        // Field() call detected - must have valid KeyPath
                        if let firstArg = functionCall.arguments.first,
                           let keyPathExpr = firstArg.expression.as(KeyPathExprSyntax.self),
                           let component = keyPathExpr.components.first,
                           let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                            let fieldName = property.declName.baseName.text

                            // Validate that the field exists in the struct
                            if fields.contains(where: { $0.name == fieldName }) {
                                pathElements.append(.keyPath(fieldName))
                                keyPathFields.append(fieldName)
                            } else {
                                // Field referenced in Field() doesn't exist
                                context.diagnose(
                                    Diagnostic(
                                        node: functionCall,
                                        message: RecordableMacroDiagnostic.directoryFieldNotFound(
                                            fieldName: fieldName,
                                            availableFields: fields.map { $0.name }
                                        )
                                    )
                                )
                                hasInvalidFields = true
                            }
                            continue
                        } else {
                            // Field() was called but KeyPath extraction failed
                            // This likely means invalid syntax or typo in field name
                            context.diagnose(
                                Diagnostic(
                                    node: functionCall,
                                    message: RecordableMacroDiagnostic.invalidFieldSyntax
                                )
                            )
                            hasInvalidFields = true
                            continue
                        }
                    }
                }
            }

            // If there were invalid fields, return nil to prevent code generation
            if hasInvalidFields {
                return nil
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

            // Extract type parameter (e.g., type: .rank)
            let indexType: IndexInfoType
            if let typeArg = arguments.first(where: { $0.label?.text == "type" }) {
                let typeStr = typeArg.expression.description.trimmingCharacters(in: CharacterSet.whitespaces)
                // Parse ".rank" -> "rank"
                let cleanType = typeStr.replacingOccurrences(of: ".", with: "")
                switch cleanType {
                case "rank":
                    indexType = .rank
                case "count":
                    indexType = .count
                case "sum":
                    indexType = .sum
                case "min":
                    indexType = .min
                case "max":
                    indexType = .max
                case "version":
                    indexType = .version
                default:
                    indexType = .value
                }
            } else {
                indexType = .value
            }

            // Extract scope parameter (e.g., scope: .global)
            let scope: IndexInfoScope
            if let scopeArg = arguments.first(where: { $0.label?.text == "scope" }) {
                let scopeStr = scopeArg.expression.description.trimmingCharacters(in: CharacterSet.whitespaces)
                // Parse ".global" -> "global"
                let cleanScope = scopeStr.replacingOccurrences(of: ".", with: "")
                scope = cleanScope == "global" ? .global : .partition
            } else {
                scope = .partition
            }

            // Process each KeyPath array argument
            for argument in arguments {
                // Skip named parameters (name, type, scope)
                if argument.label?.text == "name" ||
                   argument.label?.text == "type" ||
                   argument.label?.text == "scope" {
                    continue
                }

                let fields = extractFieldNamesFromKeyPaths(argument.expression)

                if !fields.isEmpty {
                    indexes.append(IndexInfo(
                        fields: fields,
                        isUnique: isUnique,
                        customName: customName,
                        typeName: typeName,
                        indexType: indexType,
                        scope: scope,
                        rangeMetadata: nil
                    ))
                }
            }
        }

        return indexes
    }

    /// Expand Range type indexes into multiple IndexInfo entries
    ///
    /// For each index that references a Range type field, generates 1-2 IndexInfo entries:
    /// - Range/ClosedRange: 2 indexes (start + end)
    /// - PartialRangeFrom: 1 index (start only)
    /// - PartialRangeThrough/PartialRangeUpTo: 1 index (end only)
    /// - UnboundedRange: compile error (cannot be indexed)
    ///
    /// **Example**:
    /// ```swift
    /// #Index<Event>([\.period])  // period: Range<Date>
    /// ```
    /// Expands to:
    /// ```swift
    /// IndexInfo(fields: ["period"], rangeMetadata: RangeIndexMetadata(component: "lowerBound", boundaryType: "halfOpen", originalFieldName: "period"))
    /// IndexInfo(fields: ["period"], rangeMetadata: RangeIndexMetadata(component: "upperBound", boundaryType: "halfOpen", originalFieldName: "period"))
    /// ```
    private static func expandRangeIndexes(
        indexes: [IndexInfo],
        fields: [FieldInfo]
    ) -> [IndexInfo] {
        var expandedIndexes: [IndexInfo] = []

        for index in indexes {
            // Only process VALUE indexes with a single field
            guard index.indexType == .value, index.fields.count == 1 else {
                expandedIndexes.append(index)
                continue
            }

            let fieldName = index.fields[0]

            // Find the field in FieldInfo
            guard let fieldInfo = fields.first(where: { $0.name == fieldName }) else {
                // Field not found - keep original index (error will be caught later)
                expandedIndexes.append(index)
                continue
            }

            // Normalize baseType to remove module prefixes (e.g., "Swift.Range<Date>" -> "Range<Date>")
            let normalizedType = fieldInfo.typeInfo.baseType.split(separator: ".").last.map(String.init) ?? fieldInfo.typeInfo.baseType
            // Detect Range type (use normalized baseType to handle Optional wrappers)
            let rangeInfo = RangeTypeDetector.detectRangeType(normalizedType)

            switch rangeInfo {
            case .range, .closedRange:
                // Generate 2 indexes: start + end
                let boundaryType = rangeInfo.boundaryType

                // Start index
                expandedIndexes.append(IndexInfo(
                    fields: [fieldName],
                    isUnique: index.isUnique,
                    customName: nil,  // Auto-generated name
                    typeName: index.typeName,
                    indexType: .value,
                    scope: index.scope,
                    rangeMetadata: RangeIndexMetadata(
                        component: "lowerBound",
                        boundaryType: boundaryType,
                        originalFieldName: fieldName
                    )
                ))

                // End index
                expandedIndexes.append(IndexInfo(
                    fields: [fieldName],
                    isUnique: index.isUnique,
                    customName: nil,
                    typeName: index.typeName,
                    indexType: .value,
                    scope: index.scope,
                    rangeMetadata: RangeIndexMetadata(
                        component: "upperBound",
                        boundaryType: boundaryType,
                        originalFieldName: fieldName
                    )
                ))

            case .partialRangeFrom:
                // Generate 1 index: start only
                expandedIndexes.append(IndexInfo(
                    fields: [fieldName],
                    isUnique: index.isUnique,
                    customName: nil,
                    typeName: index.typeName,
                    indexType: .value,
                    scope: index.scope,
                    rangeMetadata: RangeIndexMetadata(
                        component: "lowerBound",
                        boundaryType: "closed",
                        originalFieldName: fieldName
                    )
                ))

            case .partialRangeThrough, .partialRangeUpTo:
                // Generate 1 index: end only
                let boundaryType = rangeInfo.boundaryType

                expandedIndexes.append(IndexInfo(
                    fields: [fieldName],
                    isUnique: index.isUnique,
                    customName: nil,
                    typeName: index.typeName,
                    indexType: .value,
                    scope: index.scope,
                    rangeMetadata: RangeIndexMetadata(
                        component: "upperBound",
                        boundaryType: boundaryType,
                        originalFieldName: fieldName
                    )
                ))

            case .unboundedRange:
                // TODO: Emit compile error
                // For now, skip this index (will cause runtime error)
                continue

            case .notRange:
                // Not a Range type - keep original index
                expandedIndexes.append(index)
            }
        }

        return expandedIndexes
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
                    typeName: typeName,
                    indexType: .value,
                    scope: .partition,
                    rangeMetadata: nil
                ))
            }
        }

        return uniqueConstraints
    }

    /// Extract vector and spatial indexes from @Vector and @Spatial attributes
    ///
    /// Scans properties for @Vector and @Spatial attributes and creates IndexInfo entries.
    ///
    /// **Example**:
    /// ```swift
    /// @Vector(dimensions: 768, metric: .cosine)
    /// var embedding: Vector
    ///
    /// @Spatial(includeAltitude: true, altitudeRange: 0.0...5000.0)
    /// var position: GeoCoordinate
    /// ```
    ///
    /// - Parameters:
    ///   - members: Struct members
    ///   - typeName: Type name for index naming
    /// - Returns: Array of IndexInfo for vector/spatial indexes
    private static func extractVectorSpatialIndexes(
        from members: MemberBlockItemListSyntax,
        typeName: String
    ) -> (indexes: [IndexInfo], spatialAccessors: [SpatialAccessorInfo]) {
        var indexes: [IndexInfo] = []
        var spatialAccessors: [SpatialAccessorInfo] = []

        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }

            let fieldName = identifier.identifier.text

            // Extract field type name from type annotation
            let fieldType = binding.typeAnnotation?.type.trimmedDescription ?? "Unknown"

            // Check for @Vector attribute
            for attr in varDecl.attributes {
                guard let attributeSyntax = attr.as(AttributeSyntax.self),
                      let attrName = attributeSyntax.attributeName.as(IdentifierTypeSyntax.self)?.name.text else {
                    continue
                }

                if attrName == "Vector" {
                    // Extract parameters from @Vector(dimensions: 768, metric: .cosine)
                    var dimensions = 768  // Default
                    var metric = "cosine"  // Default

                    if case let .argumentList(arguments) = attributeSyntax.arguments {
                        for argument in arguments {
                            guard let label = argument.label?.text else { continue }

                            switch label {
                            case "dimensions":
                                if let intExpr = argument.expression.as(IntegerLiteralExprSyntax.self),
                                   let value = Int(intExpr.literal.text) {
                                    dimensions = value
                                }
                            case "metric":
                                if let memberAccess = argument.expression.as(MemberAccessExprSyntax.self) {
                                    metric = memberAccess.declName.baseName.text
                                }
                            default:
                                break
                            }
                        }
                    }

                    indexes.append(IndexInfo(
                        fields: [fieldName],
                        isUnique: false,
                        customName: nil,
                        typeName: typeName,
                        indexType: .vector(
                            dimensions: dimensions,
                            metric: metric
                        ),
                        scope: .partition,
                        rangeMetadata: nil
                    ))
                } else if attrName == "Spatial" {
                    // Extract parameters from @Spatial(type: .geo(latitude: \.lat, longitude: \.lon, level: 17), altitudeRange: 0...10000)
                    var spatialType: String?
                    var keyPaths: [String] = []
                    var level: Int? = nil
                    var altitudeRange: String? = nil

                    if case let .argumentList(arguments) = attributeSyntax.arguments {
                        for argument in arguments {
                            guard let label = argument.label?.text else { continue }

                            if label == "type" {
                                // type: is a function call expression like .geo(latitude: \.lat, longitude: \.lon, level: 17)
                                if let funcCall = argument.expression.as(FunctionCallExprSyntax.self),
                                   let callee = funcCall.calledExpression.as(MemberAccessExprSyntax.self) {
                                    // Extract spatial type name ("geo", "geo3D", "cartesian", "cartesian3D")
                                    spatialType = callee.declName.baseName.text

                                    // Extract KeyPath and level arguments
                                    for arg in funcCall.arguments {
                                        if let argLabel = arg.label?.text, argLabel == "level" {
                                            // Extract level: 17
                                            if let intExpr = arg.expression.as(IntegerLiteralExprSyntax.self),
                                               let value = Int(intExpr.literal.text) {
                                                level = value
                                            }
                                        } else if let keyPathExpr = arg.expression.as(KeyPathExprSyntax.self) {
                                            // Convert KeyPath syntax to string representation
                                            let keyPathString = extractKeyPathString(keyPathExpr)
                                            keyPaths.append(keyPathString)
                                        }
                                    }
                                }
                            } else if label == "altitudeRange" {
                                // Extract altitudeRange: 0...10000
                                // IMPORTANT: Must be a ClosedRange literal with numeric bounds
                                // Variables, function calls, or complex expressions are NOT supported

                                // Validate: Must be SequenceExprSyntax with "..." operator
                                if let sequenceExpr = argument.expression.as(SequenceExprSyntax.self) {
                                    // Check if sequence contains ClosedRangeOperator ("...")
                                    var hasClosedRangeOp = false
                                    var hasOnlyLiterals = true

                                    for element in sequenceExpr.elements {
                                        // Check for "..." operator
                                        if let binaryOp = element.as(BinaryOperatorExprSyntax.self),
                                           binaryOp.operator.text == "..." {
                                            hasClosedRangeOp = true
                                        }
                                        // Ensure operands are numeric literals (IntegerLiteralExprSyntax or FloatLiteralExprSyntax)
                                        else if !element.is(IntegerLiteralExprSyntax.self) &&
                                                  !element.is(FloatLiteralExprSyntax.self) {
                                            // Check if it's a negative sign (PrefixOperatorExprSyntax with "-")
                                            if let prefixOp = element.as(PrefixOperatorExprSyntax.self),
                                               prefixOp.operator.text == "-" {
                                                // Allow negative numbers
                                                continue
                                            } else if !element.is(BinaryOperatorExprSyntax.self) {
                                                // Non-literal found (variable, function call, etc.)
                                                hasOnlyLiterals = false
                                            }
                                        }
                                    }

                                    if hasClosedRangeOp && hasOnlyLiterals {
                                        // Valid ClosedRange literal: extract as string
                                        altitudeRange = argument.expression.description.trimmingCharacters(in: .whitespaces)
                                    } else {
                                        // Invalid: not a literal range
                                        altitudeRange = nil
                                        // TODO: Could emit diagnostic here for better UX
                                    }
                                } else {
                                    // Not a SequenceExprSyntax - invalid
                                    altitudeRange = nil
                                }
                            }
                        }
                    }

                    // Only create index if we successfully parsed type and keyPaths
                    if let spatialType = spatialType, !keyPaths.isEmpty {
                        indexes.append(IndexInfo(
                            fields: [fieldName],
                            isUnique: false,
                            customName: nil,
                            typeName: typeName,
                            indexType: .spatial(type: spatialType, keyPaths: keyPaths, level: level, altitudeRange: altitudeRange),
                            scope: .partition,
                            rangeMetadata: nil
                        ))

                        // Create SpatialAccessorInfo for type-safe coordinate extraction
                        let coordinateNames = extractCoordinateNames(from: spatialType)
                        if !coordinateNames.isEmpty {
                            spatialAccessors.append(SpatialAccessorInfo(
                                fieldName: fieldName,
                                fieldType: fieldType,
                                coordinateNames: coordinateNames,
                                relativeKeyPathStrings: keyPaths,
                                spatialType: spatialType
                            ))
                        }
                    }
                }
            }
        }

        return (indexes: indexes, spatialAccessors: spatialAccessors)
    }

    /// Extract coordinate names from spatial type string
    ///
    /// - Parameter spatialType: Spatial type string (e.g., ".geo", ".cartesian3D")
    /// - Returns: Array of coordinate names in order
    private static func extractCoordinateNames(from spatialType: String) -> [String] {
        if spatialType.hasPrefix(".geo3D") {
            return ["latitude", "longitude", "altitude"]
        } else if spatialType.hasPrefix(".geo") {
            return ["latitude", "longitude"]
        } else if spatialType.hasPrefix(".cartesian3D") {
            return ["x", "y", "z"]
        } else if spatialType.hasPrefix(".cartesian") {
            return ["x", "y"]
        } else {
            return []
        }
    }

    /// Extract KeyPath string representation from KeyPathExprSyntax
    ///
    /// Converts a KeyPath expression to its string form for code generation.
    ///
    /// **Examples**:
    /// - `\.latitude` → `"\.latitude"`
    /// - `\.address.location.latitude` → `"\.address.location.latitude"`
    ///
    /// - Parameter keyPathExpr: The KeyPath expression to convert
    /// - Returns: String representation of the KeyPath
    private static func extractKeyPathString(_ keyPathExpr: KeyPathExprSyntax) -> String {
        var pathComponents: [String] = []

        for component in keyPathExpr.components {
            if let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                pathComponents.append(property.declName.baseName.text)
            }
        }

        // Return KeyPath format: \.field1.field2.field3
        if pathComponents.isEmpty {
            return "\\."
        } else {
            return "\\." + pathComponents.joined(separator: ".")
        }
    }

    /// Deduplicate index definitions by field combination, order, uniqueness, and type
    ///
    /// Removes duplicate IndexInfo entries that have the exact same:
    /// - Field list (including order)
    /// - isUnique flag
    /// - Custom name (if specified)
    /// - Index type (value, vector, spatial)
    ///
    /// **Deduplication strategy**:
    /// - Same fields IN SAME ORDER + same isUnique + same customName + same indexType → Keep first occurrence
    /// - Different order, uniqueness, or type → Keep both
    ///
    /// **Example**:
    /// ```swift
    /// #Index<User>([\.city, \.age])     // Kept
    /// #Index<User>([\.age, \.city])     // Kept (different order)
    /// #Index<User>([\.email])           // Kept (B-tree index)
    /// #Unique<User>([\.email])          // Kept (different isUnique)
    /// @Vector(dimensions: 768)
    /// var embedding: Vector              // Kept (vector index on "embedding")
    /// #Index<Product>([\.embedding])    // Kept (B-tree index on "embedding", different type)
    /// ```
    ///
    /// - Parameter indexes: Array of IndexInfo to deduplicate
    /// - Returns: Deduplicated array (preserving original order)
    private static func deduplicateIndexes(_ indexes: [IndexInfo]) -> [IndexInfo] {
        // Use a comparable key that includes field order, isUnique, customName, indexType, AND rangeMetadata
        struct IndexKey: Hashable {
            let fields: [String]         // Preserve order
            let isUnique: Bool
            let customName: String?
            let indexType: IndexInfoType // IMPORTANT: Different index types on same field are distinct
            let rangeComponent: String?  // Range boundary component (lowerBound/upperBound)
        }

        var seen: Set<IndexKey> = []
        var result: [IndexInfo] = []

        for index in indexes {
            let key = IndexKey(
                fields: index.fields,      // Array preserves order
                isUnique: index.isUnique,
                customName: index.customName,
                indexType: index.indexType, // Consider index type for deduplication
                rangeComponent: index.rangeMetadata?.component // Consider Range component
            )
            if !seen.contains(key) {
                seen.insert(key)
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

            // Get type - require explicit type annotation
            guard let type = binding.typeAnnotation?.type else {
                // Emit diagnostic for missing type annotation
                context.diagnose(
                    Diagnostic(
                        node: binding,
                        message: RecordableMacroDiagnostic.typeAnnotationRequired(fieldName: fieldName)
                    )
                )
                continue
            }

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

    /// Generate CodingKeys enum for Protobuf encoder/decoder
    ///
    /// Generates an enum with:
    /// - String and CodingKey conformance
    /// - Cases for each persistent field
    /// - intValue computed property returning field index (0-based)
    /// - init?(intValue:) initializer for decoding
    private static func generateCodingKeys(
        fields: [FieldInfo]
    ) -> DeclSyntax {
        // Generate case declarations
        let cases = fields.map { field in
            "case \(field.name)"
        }.joined(separator: "\n        ")

        // Generate intValue switch cases (Protobuf field numbers start from 1)
        let intValueCases = fields.enumerated().map { index, field in
            "case .\(field.name): return \(index + 1)"
        }.joined(separator: "\n            ")

        // Generate init?(intValue:) switch cases (Protobuf field numbers start from 1)
        let initCases = fields.enumerated().map { index, field in
            "case \(index + 1): self = .\(field.name)"
        }.joined(separator: "\n            ")

        return """
        enum CodingKeys: String, CodingKey {
            \(raw: cases)

            var intValue: Int? {
                switch self {
                \(raw: intValueCases)
                }
            }

            init?(intValue: Int) {
                switch intValue {
                \(raw: initCases)
                default: return nil
                }
            }
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
        let allIndexes = indexInfo

        guard !allIndexes.isEmpty else {
            return ("", "")
        }

        // Generate static IndexDefinition properties with getter to avoid circular reference
        let staticProperties = allIndexes.map { info in
            let varName = info.variableName()
            let indexName = info.indexName()
            // Use string-based initializer to preserve nested field paths (e.g., "address.city")
            // IndexInfo.fields already contains the correct dot-notation for nested fields
            let fieldsLiteral = info.fields.map { "\"\($0)\"" }.joined(separator: ", ")
            let unique = info.isUnique ? "true" : "false"

            // Generate indexType parameter based on index type
            let indexTypeParam: String
            switch info.indexType {
            case .value:
                indexTypeParam = "indexType: .value"
            case .rank:
                indexTypeParam = "indexType: .rank"
            case .count:
                indexTypeParam = "indexType: .count"
            case .sum:
                indexTypeParam = "indexType: .sum"
            case .min:
                indexTypeParam = "indexType: .min"
            case .max:
                indexTypeParam = "indexType: .max"
            case .vector(let dimensions, let metric):
                indexTypeParam = """
indexType: .vector(VectorIndexOptions(
                            dimensions: \(dimensions),
                            metric: .\(metric)
                        ))
"""
            case .spatial(let type, let keyPaths, let level, let altitudeRange):
                // Generate SpatialType enum case with KeyPaths and optional level
                let spatialTypeInit: String
                switch type {
                case "geo":
                    // .geo(latitude: \.lat, longitude: \.lon, level: 17)
                    guard keyPaths.count == 2 else {
                        if let levelValue = level {
                            spatialTypeInit = ".geo(latitude: \\.latitude, longitude: \\.longitude, level: \(levelValue))"
                        } else {
                            spatialTypeInit = ".geo(latitude: \\.latitude, longitude: \\.longitude)"
                        }
                        break
                    }
                    if let levelValue = level {
                        spatialTypeInit = ".geo(latitude: \(keyPaths[0]), longitude: \(keyPaths[1]), level: \(levelValue))"
                    } else {
                        spatialTypeInit = ".geo(latitude: \(keyPaths[0]), longitude: \(keyPaths[1]))"
                    }

                case "geo3D":
                    // .geo3D(latitude: \.lat, longitude: \.lon, altitude: \.alt, level: 16)
                    guard keyPaths.count == 3 else {
                        if let levelValue = level {
                            spatialTypeInit = ".geo3D(latitude: \\.latitude, longitude: \\.longitude, altitude: \\.altitude, level: \(levelValue))"
                        } else {
                            spatialTypeInit = ".geo3D(latitude: \\.latitude, longitude: \\.longitude, altitude: \\.altitude)"
                        }
                        break
                    }
                    if let levelValue = level {
                        spatialTypeInit = ".geo3D(latitude: \(keyPaths[0]), longitude: \(keyPaths[1]), altitude: \(keyPaths[2]), level: \(levelValue))"
                    } else {
                        spatialTypeInit = ".geo3D(latitude: \(keyPaths[0]), longitude: \(keyPaths[1]), altitude: \(keyPaths[2]))"
                    }

                case "cartesian":
                    // .cartesian(x: \.x, y: \.y, level: 18)
                    guard keyPaths.count == 2 else {
                        if let levelValue = level {
                            spatialTypeInit = ".cartesian(x: \\.x, y: \\.y, level: \(levelValue))"
                        } else {
                            spatialTypeInit = ".cartesian(x: \\.x, y: \\.y)"
                        }
                        break
                    }
                    if let levelValue = level {
                        spatialTypeInit = ".cartesian(x: \(keyPaths[0]), y: \(keyPaths[1]), level: \(levelValue))"
                    } else {
                        spatialTypeInit = ".cartesian(x: \(keyPaths[0]), y: \(keyPaths[1]))"
                    }

                case "cartesian3D":
                    // .cartesian3D(x: \.x, y: \.y, z: \.z, level: 16)
                    guard keyPaths.count == 3 else {
                        if let levelValue = level {
                            spatialTypeInit = ".cartesian3D(x: \\.x, y: \\.y, z: \\.z, level: \(levelValue))"
                        } else {
                            spatialTypeInit = ".cartesian3D(x: \\.x, y: \\.y, z: \\.z)"
                        }
                        break
                    }
                    if let levelValue = level {
                        spatialTypeInit = ".cartesian3D(x: \(keyPaths[0]), y: \(keyPaths[1]), z: \(keyPaths[2]), level: \(levelValue))"
                    } else {
                        spatialTypeInit = ".cartesian3D(x: \(keyPaths[0]), y: \(keyPaths[1]), z: \(keyPaths[2]))"
                    }

                default:
                    // Fallback for unknown types
                    spatialTypeInit = ".geo(latitude: \\.latitude, longitude: \\.longitude)"
                }

                // Generate SpatialIndexOptions with altitudeRange if present (for 3D types)
                if let altitudeRangeValue = altitudeRange {
                    indexTypeParam = """
indexType: .spatial(SpatialIndexOptions(type: \(spatialTypeInit), altitudeRange: \(altitudeRangeValue)))
"""
                } else {
                    indexTypeParam = """
indexType: .spatial(SpatialIndexOptions(type: \(spatialTypeInit)))
"""
                }
            case .version:
                indexTypeParam = "indexType: .version"
            }

            // Generate scope parameter
            let scopeParam = "scope: .\(info.scope.rawValue)"

            // Generate Range parameters if present
            let rangeParams: String
            if let rangeMetadata = info.rangeMetadata {
                rangeParams = """
,
                        rangeComponent: .\(rangeMetadata.component),
                        boundaryType: .\(rangeMetadata.boundaryType)
"""
            } else {
                rangeParams = ""
            }

            return """

                public static var \(varName): IndexDefinition {
                    IndexDefinition(
                        name: "\(indexName)",
                        recordType: "\(typeName)",
                        fields: [\(fieldsLiteral)],
                        unique: \(unique),
                        \(indexTypeParam),
                        \(scopeParam)\(rangeParams)
                    )
                }
            """
        }.joined()

        // Generate indexDefinitions array property
        let indexNames = allIndexes.map { $0.variableName() }.joined(separator: ", ")
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
            // Note: All fields have been validated in extractDirectoryMetadata,
            // so this should never fail. If it does, it's an internal error.
            let parameters = metadata.keyPathFields.compactMap { fieldName -> String? in
                if let field = fields.first(where: { $0.name == fieldName }) {
                    return "\(fieldName): \(field.type)"
                } else {
                    // Internal error: field should have been validated already
                    return nil
                }
            }.joined(separator: ", ")

            // If any field is missing, return early (internal error)
            guard parameters.components(separatedBy: ", ").count == metadata.keyPathFields.count else {
                return ""
            }

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

    /// Generate validation methods for @Vector and @Spatial fields
    ///
    /// This method scans indexInfo for vector/spatial indexes and generates
    /// validation methods that check protocol conformance and data validity.
    ///
    /// - Parameters:
    ///   - indexInfo: Array of IndexInfo containing vector/spatial indexes
    ///   - fields: Array of FieldInfo for field name lookup
    /// - Returns: Generated validation methods as a string
    private static func generateValidationMethods(
        indexInfo: [IndexInfo],
        fields: [FieldInfo]
    ) -> String {
        var methods: [String] = []

        // Extract vector indexes
        let vectorIndexes = indexInfo.filter {
            if case .vector = $0.indexType { return true }
            return false
        }

        // Extract spatial indexes
        let spatialIndexes = indexInfo.filter {
            if case .spatial = $0.indexType { return true }
            return false
        }

        // Generate validateVectorFields() if there are vector indexes
        if !vectorIndexes.isEmpty {
            var validationCases: [String] = []

            for indexDef in vectorIndexes {
                guard let fieldName = indexDef.fields.first else { continue }

                if case .vector(let dimensions, _) = indexDef.indexType {
                    let validation = """
// Validate field '\(fieldName)' with @Vector attribute
                guard let vectorField = self.\(fieldName) as? any VectorRepresentable else {
                    throw RecordLayerError.invalidArgument(
                        "Field '\(fieldName)' with @Vector attribute must conform to VectorRepresentable protocol.\\n" +
                        "Expected type: Vector or any custom type conforming to VectorRepresentable\\n" +
                        "Actual type: \\(type(of: self.\(fieldName)))"
                    )
                }

                // Validate dimensions
                guard vectorField.dimensions == \(dimensions) else {
                    throw RecordLayerError.invalidArgument(
                        "Field '\(fieldName)' dimension mismatch: expected \(dimensions), got \\(vectorField.dimensions).\\n" +
                        "Ensure that the vector data matches the dimensions specified in @Vector macro:\\n" +
                        "  @Vector(dimensions: \(dimensions)) var \(fieldName): Vector"
                    )
                }

                // Validate toFloatArray() can be called
                let _ = vectorField.toFloatArray()
"""
                    validationCases.append(validation)
                }
            }

            let method = """

            public func validateVectorFields() throws {
                \(validationCases.joined(separator: "\n\n                "))
            }
"""
            methods.append(method)
        }

        // Generate validateSpatialFields() if there are spatial indexes
        if !spatialIndexes.isEmpty {
            var validationCases: [String] = []

            for indexDef in spatialIndexes {
                guard let fieldName = indexDef.fields.first else { continue }

                if case .spatial(let type, _, _, _) = indexDef.indexType {
                    // Determine expected dimensionality based on SpatialType
                    let is3D = type == "geo3D" || type == "cartesian3D"
                    let expectedDims = is3D ? 3 : 2
                    let dimsDescription = is3D ? "[longitude, latitude, altitude]" : "[longitude, latitude]"

                    let validation = """
// Validate field '\(fieldName)' with @Spatial(type: .\(type)) attribute
                guard let spatialField = self.\(fieldName) as? any SpatialRepresentable else {
                    throw RecordLayerError.invalidArgument(
                        "Field '\(fieldName)' with @Spatial attribute must conform to SpatialRepresentable protocol.\\n" +
                        "Expected type: GeoCoordinate or any custom type conforming to SpatialRepresentable\\n" +
                        "Actual type: \\(type(of: self.\(fieldName)))"
                    )
                }

                // Validate dimensionality matches spatial type
                let coords = spatialField.toNormalizedCoordinates()
                guard coords.count == \(expectedDims) else {
                    throw RecordLayerError.invalidArgument(
                        "Field '\(fieldName)' with @Spatial(type: .\(type)) must provide \(expectedDims)D coordinates.\\n" +
                        "Expected: \(dimsDescription)\\n" +
                        "Got: \\(coords.count) dimensions"
                    )
                }
"""
                    validationCases.append(validation)
                }
            }

            let method = """

            public func validateSpatialFields() throws {
                \(validationCases.joined(separator: "\n\n                "))
            }
"""
            methods.append(method)
        }

        return methods.joined(separator: "\n")
    }

    /// Generate static method implementation for spatial coordinate accessors
    ///
    /// **Purpose**: Eliminates Mirror-based reflection in SpatialIndexMaintainer
    /// by providing compile-time type-safe PartialKeyPath accessors via KeyPath composition.
    ///
    /// **Design**: Relative KeyPath Composition
    /// - User specifies relative KeyPaths from field type (e.g., `\.latitude` from `Location` type)
    /// - Macro auto-detects field name (e.g., "location") and field type (e.g., "Location")
    /// - Macro composes absolute KeyPath: `\Self.location` + `\.latitude` = `\Self.location.latitude`
    ///
    /// **Generated code example**:
    /// ```swift
    /// // For: @Spatial(type: .geo(latitude: \.latitude, longitude: \.longitude, level: 17)) var location: Location
    /// // Macro auto-detected: fieldName="location", fieldType="Location"
    /// // Relative KeyPaths: \.latitude, \.longitude (from Location type)
    /// // Composed absolute KeyPaths: \Self.location.latitude, \Self.location.longitude
    ///
    /// public static func spatialKeyPath(field: String, coordinate: String) -> PartialKeyPath<Self>? {
    ///     switch (field, coordinate) {
    ///     case ("location", "latitude"): return \Self.location.latitude
    ///     case ("location", "longitude"): return \Self.location.longitude
    ///     default: return nil
    ///     }
    /// }
    /// ```
    ///
    /// **Usage in SpatialIndexMaintainer**:
    /// ```swift
    /// if let partialKeyPath = Record.spatialKeyPath(field: "location", coordinate: "latitude") {
    ///     let value = record[keyPath: partialKeyPath] as! Double
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - typeName: Fully qualified type name for KeyPath type (e.g., "MyModule.MyRecord")
    ///   - spatialAccessors: Collected spatial accessor metadata from @Spatial attributes
    /// - Returns: String containing static subscript implementation
    private static func generateSpatialAccessorProperties(
        typeName: String,
        spatialAccessors: [SpatialAccessorInfo]
    ) -> String {
        guard !spatialAccessors.isEmpty else {
            return ""
        }

        var cases: [String] = []

        for accessor in spatialAccessors {
            // Generate case for each coordinate
            for (index, coordinateName) in accessor.coordinateNames.enumerated() {
                guard index < accessor.relativeKeyPathStrings.count else { continue }

                let relativeKeyPath = accessor.relativeKeyPathStrings[index]

                // Compose absolute KeyPath: \Self.fieldName + relative KeyPath
                // Example: \Self.location + \.latitude = \Self.location.latitude
                let absoluteKeyPath = composeAbsoluteKeyPath(
                    fieldName: accessor.fieldName,
                    relativeKeyPath: relativeKeyPath
                )

                // Generate switch case: case ("fieldName", "coordinateName"): return \Self.field.coordinate
                let caseClause = """
                case ("\(accessor.fieldName)", "\(coordinateName)"): return \(absoluteKeyPath)
"""
                cases.append(caseClause)
            }
        }

        // Generate complete static method implementation
        return """


            public static func spatialKeyPath(field: String, coordinate: String) -> PartialKeyPath<Self>? {
                switch (field, coordinate) {
                \(cases.joined(separator: "\n                "))
                default: return nil
                }
            }
"""
    }

    /// Compose absolute KeyPath from field name and relative KeyPath
    ///
    /// **Examples**:
    /// - `composeAbsoluteKeyPath("location", "\.latitude")` → `\Self.location.latitude`
    /// - `composeAbsoluteKeyPath("address", "\.location.latitude")` → `\Self.address.location.latitude`
    ///
    /// - Parameters:
    ///   - fieldName: Field name (e.g., "location")
    ///   - relativeKeyPath: Relative KeyPath string from field type (e.g., "\.latitude")
    /// - Returns: Absolute KeyPath string (e.g., "\Self.location.latitude")
    private static func composeAbsoluteKeyPath(fieldName: String, relativeKeyPath: String) -> String {
        // Remove leading "\." from relative KeyPath
        let relativeWithoutPrefix = relativeKeyPath.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^\\\\\\.", with: "", options: .regularExpression)

        // Compose: \Self.fieldName.relativePath
        return "\\Self.\(fieldName).\(relativeWithoutPrefix)"
    }

    /// Generate extractRangeBoundary method for Range type fields
    private static func generateRangeBoundaryMethod(
        typeName: String,
        fields: [FieldInfo]
    ) -> String {
        // Find all Range type fields
        let rangeFields = fields.filter { field in
            let typeInfo = analyzeType(field.type)
            if case .range = typeInfo.category {
                return true
            }
            return false
        }

        // No Range fields - no need to generate extractRangeBoundary method
        // (The protocol extension default implementation using Reflection will be used)
        guard !rangeFields.isEmpty else {
            return ""
        }

        // Generate switch cases for each Range field
        var caseClauses: [String] = []

        for field in rangeFields {
            let typeInfo = analyzeType(field.type)
            let rangeInfo = RangeTypeDetector.detectRangeType(typeInfo.baseType)

            switch rangeInfo {
            case .range, .closedRange:
                // For Range and ClosedRange, handle both lowerBound and upperBound
                let caseClause = """
                case "\(field.name)":
                        \(typeInfo.isOptional ? """
                        guard let rangeValue = self.\(field.name) else {
                            return []  // Optional Range is nil
                        }
                        """ : "let rangeValue = self.\(field.name)")
                        switch component {
                        case .lowerBound:
                            return [rangeValue.lowerBound as any TupleElement]
                        case .upperBound:
                            return [rangeValue.upperBound as any TupleElement]
                        }
                """
                caseClauses.append(caseClause)

            case .partialRangeFrom:
                // For PartialRangeFrom, only lowerBound exists
                let caseClause = """
                case "\(field.name)":
                        \(typeInfo.isOptional ? """
                        guard let rangeValue = self.\(field.name) else {
                            return []  // Optional Range is nil
                        }
                        """ : "let rangeValue = self.\(field.name)")
                        guard component == .lowerBound else {
                            throw RecordLayerError.invalidArgument("PartialRangeFrom only supports lowerBound component")
                        }
                        return [rangeValue.lowerBound as any TupleElement]
                """
                caseClauses.append(caseClause)

            case .partialRangeUpTo, .partialRangeThrough:
                // For PartialRange..., only upperBound exists
                let caseClause = """
                case "\(field.name)":
                        \(typeInfo.isOptional ? """
                        guard let rangeValue = self.\(field.name) else {
                            return []  // Optional Range is nil
                        }
                        """ : "let rangeValue = self.\(field.name)")
                        guard component == .upperBound else {
                            throw RecordLayerError.invalidArgument("Partial range only supports upperBound component")
                        }
                        return [rangeValue.upperBound as any TupleElement]
                """
                caseClauses.append(caseClause)

            case .unboundedRange:
                // UnboundedRange should have been caught during index expansion
                continue

            case .notRange:
                continue
            }
        }

        // Generate the complete method
        return """
            public func extractRangeBoundary(
                fieldName: String,
                component: RangeComponent
            ) throws -> [any TupleElement] {
                switch fieldName {
                \(caseClauses.joined(separator: "\n\n                "))
                default:
                    throw RecordLayerError.fieldNotFound("Field '\\(fieldName)' not found or not a Range type. Available Range fields: \(rangeFields.map { $0.name }.joined(separator: ", "))")
                }
            }
        """
    }

    private static func generateRecordableExtension(
        typeName: String,  // Fully qualified name for extension declaration and KeyPaths
        recordName: String,
        fields: [FieldInfo],
        primaryKeyFields: [FieldInfo],
        directoryMetadata: DirectoryMetadata?,
        indexInfo: [IndexInfo],
        simpleTypeName: String,  // Simple name for recordType identifier
        spatialAccessors: [SpatialAccessorInfo]  // Type-safe spatial coordinate accessors
    ) throws -> ExtensionDeclSyntax {

        let fieldNames = fields.map { "\"\($0.name)\"" }.joined(separator: ", ")
        let primaryKeyNames = primaryKeyFields.map { "\"\($0.name)\"" }.joined(separator: ", ")

        // Generate field numbers (1-indexed, based on declaration order)
        let fieldNumberCases = fields.enumerated().map { index, field in
            let fieldNumber = index + 1
            return "case \"\(field.name)\": return \(fieldNumber)"
        }.joined(separator: "\n            ")

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

        // Generate validation methods for @Vector/@Spatial fields
        let validationMethods = generateValidationMethods(indexInfo: indexInfo, fields: fields)

        // Generate extractRangeBoundary method for Range type fields
        // Note: RecordableExtensions.swift has NO default implementation, so this is required
        let rangeBoundaryMethod = generateRangeBoundaryMethod(typeName: typeName, fields: fields)

        // Generate spatial coordinate accessor KeyPaths (type-safe, no Mirror)
        let spatialAccessorProperties = generateSpatialAccessorProperties(
            typeName: typeName,
            spatialAccessors: spatialAccessors
        )

        let extensionCode: DeclSyntax = """
        extension \(raw: typeName): Recordable {
            public static var recordName: String { "\(raw: recordName)" }

            public static var primaryKeyFields: [String] { [\(raw: primaryKeyNames)] }

            public static var allFields: [String] { [\(raw: fieldNames)] }

            public static var supportsReconstruction: Bool { \(raw: supportsReconstructionValue) }
            \(raw: indexStaticProperties)\(raw: indexDefinitionsProperty)\(raw: enumMetadataMethod)\(raw: spatialAccessorProperties)

            public static func fieldNumber(for fieldName: String) -> Int? {
                switch fieldName {
                \(raw: fieldNumberCases)
                default: return nil
                }
            }

            \(raw: generateReconstructMethodIfSupported(typeName: typeName, fields: fields, primaryKeyFields: primaryKeyFields))
            \(raw: directoryMethods)
            \(raw: validationMethods)
            \(raw: rangeBoundaryMethod)
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

    /// Classify a type as primitive, range, or custom
    private static func classifyType(_ type: String) -> TypeCategory {
        // IMPORTANT: Check for Range types FIRST before module normalization
        // because Range types contain generic parameters that may include module-qualified types
        // (e.g., "ClosedRange<Foundation.Date>" would be incorrectly split by ".")
        if type.contains("Range<") || type == "UnboundedRange" {
            // Check for Range types without normalization to handle generic parameters correctly
            if type.hasPrefix("Range<") || type.contains(".Range<") {
                return .range
            }
            if type.hasPrefix("ClosedRange<") || type.contains(".ClosedRange<") {
                return .range
            }
            if type.hasPrefix("PartialRangeFrom<") || type.contains(".PartialRangeFrom<") {
                return .range
            }
            if type.hasPrefix("PartialRangeThrough<") || type.contains(".PartialRangeThrough<") {
                return .range
            }
            if type.hasPrefix("PartialRangeUpTo<") || type.contains(".PartialRangeUpTo<") {
                return .range
            }
            if type == "UnboundedRange" || type.hasSuffix(".UnboundedRange") {
                return .range
            }
        }

        // Normalize type by removing module prefixes (e.g., "Swift.Int64" -> "Int64", "Foundation.Data" -> "Data")
        // This is safe for primitive types since they don't have generic parameters
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
                        return EnumMetadata(
                            typeName: "\(enumTypeName)",
                            cases: cases
                        )
                    }
                    return nil
            """
        }.joined(separator: "\n            ")

        return """

            public static func enumMetadata(for fieldName: String) -> EnumMetadata? {
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
        // Filter out transient, PK, array, custom type, and Range type fields
        // (arrays, custom types, and Range types can't be directly indexed or covered as single TupleElements)
        let nonPKFields = fields.filter { field in
            if field.isTransient || primaryKeyFields.contains(field.name) || field.typeInfo.isArray {
                return false
            }
            // Also filter out custom types
            switch field.typeInfo.category {
            case .custom:
                return false
            default:
                break
            }
            // Filter out Range types (Range<T>, ClosedRange<T>, PartialRange*)
            // Range fields are split into start/end indexes and cannot be extracted as single TupleElements
            let normalizedType = field.typeInfo.baseType
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "?", with: "")
            if normalizedType.hasPrefix("Range<") ||
               normalizedType.hasPrefix("ClosedRange<") ||
               normalizedType.hasPrefix("PartialRangeFrom<") ||
               normalizedType.hasPrefix("PartialRangeThrough<") ||
               normalizedType.hasPrefix("PartialRangeUpTo<") {
                return false
            }
            return true
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
    /// - It's a non-optional Range type (Range<T>, ClosedRange<T>)
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

            // Check for non-optional Range type (including PartialRange*)
            let normalizedType = field.typeInfo.baseType
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "?", with: "")
            if normalizedType.hasPrefix("Range<") ||
               normalizedType.hasPrefix("ClosedRange<") ||
               normalizedType.hasPrefix("PartialRangeFrom<") ||
               normalizedType.hasPrefix("PartialRangeThrough<") ||
               normalizedType.hasPrefix("PartialRangeUpTo<") {
                if !field.typeInfo.isOptional {
                    // Non-optional Range type cannot be reconstructed from index
                    return true
                }
            }
        }
        return false
    }

    /// Generate default values for array, custom type, and Range type fields
    private static func generateArrayAndCustomTypeDefaults(fields: [FieldInfo], primaryKeyFields: Set<String>) -> String {
        let nonIndexableFields = fields.filter { field in
            if field.isTransient || primaryKeyFields.contains(field.name) {
                return false
            }
            // Check for array, custom type, or Range type
            if field.typeInfo.isArray {
                return true
            }
            switch field.typeInfo.category {
            case .custom:
                return true
            default:
                break
            }
            // Check for Range types (including PartialRange*)
            let normalizedType = field.typeInfo.baseType
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "?", with: "")
            if normalizedType.hasPrefix("Range<") ||
               normalizedType.hasPrefix("ClosedRange<") ||
               normalizedType.hasPrefix("PartialRangeFrom<") ||
               normalizedType.hasPrefix("PartialRangeThrough<") ||
               normalizedType.hasPrefix("PartialRangeUpTo<") {
                return true
            }
            return false
        }

        return nonIndexableFields.map { field in
            // Determine if this is a Range type (including PartialRange*)
            let normalizedType = field.typeInfo.baseType
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "?", with: "")
            let isRangeType = normalizedType.hasPrefix("Range<") ||
                             normalizedType.hasPrefix("ClosedRange<") ||
                             normalizedType.hasPrefix("PartialRangeFrom<") ||
                             normalizedType.hasPrefix("PartialRangeThrough<") ||
                             normalizedType.hasPrefix("PartialRangeUpTo<")

            if field.typeInfo.isArray {
                if field.typeInfo.isOptional {
                    return "let \(field.name): \(field.type) = nil"
                } else {
                    return "let \(field.name): \(field.type) = []"
                }
            } else if isRangeType {
                // Range types cannot be reconstructed from indexes
                if field.typeInfo.isOptional {
                    return "let \(field.name): \(field.type) = nil  // Range type - cannot reconstruct from index"
                } else {
                    // Required Range type - throw error instead of crashing
                    // Note: This should not be reached if supportsReconstruction = false is respected
                    let baseTypeName = field.typeInfo.baseType
                    return """
                    // Required Range type - cannot reconstruct from index
                    throw RecordLayerError.reconstructionFailed(
                        recordType: "\\(Self.recordName)",
                        reason: "Field '\(field.name)' is a required Range type (\(baseTypeName)) and cannot be reconstructed from index. This record does not support covering index reconstruction."
                    )
                    """
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
    case range                 // Range types (Range, ClosedRange, PartialRange*)
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

/// Index type for macro-generated indexes
enum IndexInfoType: Hashable {
    case value
    case rank
    case count
    case sum
    case min
    case max
    case vector(dimensions: Int, metric: String)
    /// Spatial index with KeyPath-based coordinate extraction
    ///
    /// - Parameters:
    ///   - type: Spatial type ("geo", "geo3D", "cartesian", "cartesian3D")
    ///   - keyPaths: Array of KeyPath strings for coordinate extraction
    ///     - geo: [latitude, longitude]
    ///     - geo3D: [latitude, longitude, altitude]
    ///     - cartesian: [x, y]
    ///     - cartesian3D: [x, y, z]
    ///   - level: Optional level parameter for precision control
    ///   - altitudeRange: Optional altitude range for 3D types (e.g., "0...10000")
    case spatial(type: String, keyPaths: [String], level: Int?, altitudeRange: String?)
    case version
}

enum IndexInfoScope: String, Hashable {
    case partition
    case global
}

/// Range index metadata for Range-generated indexes
struct RangeIndexMetadata {
    let component: String          // "lowerBound" or "upperBound"
    let boundaryType: String       // "halfOpen" or "closed"
    let originalFieldName: String  // Original Range field name
}

/// Information extracted from #Index, #Unique, @Vector, or @Spatial macro calls
struct IndexInfo {
    let fields: [String]      // Field names extracted from KeyPaths or property names
    let isUnique: Bool         // true for #Unique, false for #Index
    let customName: String?    // Custom name from 'name:' parameter
    let typeName: String       // Type name from generic parameter
    let indexType: IndexInfoType  // Index type (.value, .vector, .spatial)
    let scope: IndexInfoScope     // Index scope (.partition, .global)
    let rangeMetadata: RangeIndexMetadata?  // nil for non-Range indexes

    /// Generate the index name (e.g., "User_email_unique" or "location_index")
    func indexName() -> String {
        if let customName = customName {
            return customName
        }

        // For Range-generated indexes, use pattern: "TypeName_fieldName_start_index" or "TypeName_fieldName_end_index"
        if let rangeMetadata = rangeMetadata {
            let componentSuffix = rangeMetadata.component == "lowerBound" ? "start" : "end"
            return "\(typeName)_\(rangeMetadata.originalFieldName)_\(componentSuffix)_index"
        }

        let fieldNames = fields.joined(separator: "_")
        let suffix: String
        switch indexType {
        case .value:
            suffix = isUnique ? "unique" : "index"
        case .rank:
            suffix = "rank"
        case .count:
            suffix = "count"
        case .sum:
            suffix = "sum"
        case .min:
            suffix = "min"
        case .max:
            suffix = "max"
        case .vector:
            suffix = "vector"
        case .spatial:
            suffix = "spatial"
        case .version:
            suffix = "version"
        }
        return "\(typeName)_\(fieldNames)_\(suffix)"
    }

    /// Generate the variable name (replace dots with double underscores)
    func variableName() -> String {
        return indexName().replacingOccurrences(of: ".", with: "__")
    }
}

// MARK: - Diagnostic Messages

enum RecordableMacroDiagnostic {
    case primaryKeyFieldNotFound(missingFields: [String], availableFields: [String])
    case typeAnnotationRequired(fieldName: String)
    case directoryFieldNotFound(fieldName: String, availableFields: [String])
    case invalidFieldSyntax
}

extension RecordableMacroDiagnostic: DiagnosticMessage {
    var message: String {
        switch self {
        case .primaryKeyFieldNotFound(let missingFields, let availableFields):
            return """
            Primary key field(s) not found: \(missingFields.joined(separator: ", "))
            Available fields: \(availableFields.joined(separator: ", "))
            Make sure all fields in #PrimaryKey exist in the struct.
            """

        case .typeAnnotationRequired(let fieldName):
            return """
            Type annotation required for field '\(fieldName)'
            Properties without explicit type annotations (e.g., 'var name = ""') cannot be serialized.
            Add an explicit type: 'var \(fieldName): String'
            """

        case .directoryFieldNotFound(let fieldName, let availableFields):
            return """
            Directory field reference not found: \(fieldName)
            Available fields: \(availableFields.joined(separator: ", "))
            Check for typos in Field(\\Type.fieldName) within #Directory.
            """

        case .invalidFieldSyntax:
            return """
            Invalid Field() syntax in #Directory
            Field() requires a KeyPath argument: Field(\\Type.fieldName)
            """
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "FDBRecordLayerMacros", id: "RecordableMacro")
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
