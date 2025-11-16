import Foundation
import FoundationDB
import FDBRecordCore

// MARK: - FDB-Specific Recordable Extensions

/// Type-erased primary key value for backward compatibility
public typealias DefaultPrimaryKeyValue = Tuple

/// FDB-specific extensions to Recordable protocol
///
/// These extensions add FoundationDB-specific functionality to the core Recordable protocol.
/// They are only available in FDBRecordLayer (server-side) and not in client apps.
public extension Recordable {
    /// Associated type for primary key value (FDB-specific)
    ///
    /// This associatedtype exists only in FDBRecordLayer and is not part of FDBRecordCore.
    /// It allows each Recordable type to specify its primary key type.
    /// For backward compatibility, it defaults to Tuple.
    typealias PrimaryKeyValue = Tuple

    /// Type-safe primary key definition using KeyPaths (FDB-specific)
    ///
    /// This property exists only in FDBRecordLayer and is not part of FDBRecordCore.
    /// If implemented, it will be used instead of `primaryKeyFields` for:
    /// - Schema definition (Entity.primaryKeyExpression)
    /// - Primary key extraction (via primaryKeyValue)
    ///
    /// **Default Implementation**: Returns nil (uses old API)
    static var primaryKeyPaths: PrimaryKeyPaths<Self, Tuple>? {
        return nil
    }

    /// Type-safe primary key value (FDB-specific)
    ///
    /// This property exists only in FDBRecordLayer and is not part of FDBRecordCore.
    /// It extracts the primary key value using the type specified in `PrimaryKeyValue` associatedtype.
    ///
    /// **Default Implementation**: Returns nil (uses extractPrimaryKey() instead)
    var primaryKeyValue: Tuple? {
        return nil
    }

    /// Extract the value of a specified field (for indexing)
    ///
    /// Used during index construction.
    /// Returns the value corresponding to the field name as an array of `TupleElement`.
    ///
    /// **Note**: This method is implemented by RecordAccess using Swift Mirror.
    /// Direct protocol implementation is deprecated in favor of reflection-based extraction.
    ///
    /// **Examples**:
    /// ```swift
    /// user.extractField("email")  // -> ["alice@example.com"]
    /// user.extractField("tags")   // -> ["swift", "ios", "development"]
    /// ```
    ///
    /// - Parameter fieldName: Field name
    /// - Returns: Array of field values (multiple elements for array-type fields)
    func extractField(_ fieldName: String) -> [any TupleElement] {
        // This default implementation uses Swift Mirror for reflection
        let mirror = Mirror(reflecting: self)

        for child in mirror.children {
            if child.label == fieldName {
                return convertToTupleElements(child.value)
            }
        }

        return []
    }

    /// Extract primary key as Tuple
    ///
    /// Returns the record's primary key in FoundationDB Tuple format.
    /// For a single primary key, it's a 1-element Tuple; for composite keys, it's a multi-element Tuple.
    ///
    /// **Note**: This method is implemented by RecordAccess using Swift Mirror.
    /// Direct protocol implementation is deprecated in favor of reflection-based extraction.
    ///
    /// **Examples**:
    /// ```swift
    /// user.extractPrimaryKey()  // -> Tuple(123)
    /// order.extractPrimaryKey() // -> Tuple("tenant_a", 456)  // Composite key
    /// ```
    ///
    /// - Returns: Primary key Tuple
    func extractPrimaryKey() -> Tuple {
        // This default implementation uses Swift Mirror for reflection
        let mirror = Mirror(reflecting: self)
        var elements: [any TupleElement] = []

        for fieldName in Self.primaryKeyFields {
            for child in mirror.children {
                if child.label == fieldName {
                    if let tupleElement = convertToTupleElement(child.value) {
                        elements.append(tupleElement)
                    }
                    break
                }
            }
        }

        return Tuple(elements)
    }

    /// Reconstruct a record from covering index key and value
    ///
    /// This method is used by covering indexes to rebuild records without
    /// fetching from storage. The @Recordable macro automatically generates
    /// this implementation.
    ///
    /// **Index key structure**: `<indexSubspace><rootExpression fields><primaryKey fields>`
    /// **Index value structure**: Tuple-packed covering field values
    ///
    /// **Field Assembly Strategy**:
    /// 1. Extract indexed fields from index key (via index.rootExpression)
    /// 2. Extract primary key from index key (last N elements)
    /// 3. Extract covering fields from index value (via index.coveringFields)
    /// 4. Reconstruct record with all available fields
    ///
    /// - Parameters:
    ///   - indexKey: Index key (unpacked tuple)
    ///   - indexValue: Index value (packed covering fields)
    ///   - index: Index definition
    ///   - primaryKeyExpression: Primary key expression for field extraction
    /// - Returns: Reconstructed record
    /// - Throws: RecordLayerError.reconstructionNotImplemented by default
    static func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Self {
        throw RecordLayerError.reconstructionNotImplemented(
            recordType: String(describing: Self.self),
            suggestion: """
            To use covering indexes with this record type, the @Recordable macro
            must generate a reconstruct() implementation. Make sure you are using
            the latest version of the @Recordable macro.
            """
        )
    }

    /// Indicates whether this type supports covering index reconstruction
    ///
    /// Returns `true` if the type implements `reconstruct()` method properly.
    /// This allows the query planner to safely use covering index optimization.
    ///
    /// **Default**: `false` (safe, conservative)
    ///
    /// **Auto-Generated**: `@Recordable` macro sets this to `true`
    ///
    /// - Returns: `true` if reconstruction is supported, `false` otherwise
    static var supportsReconstruction: Bool {
        return false
    }

    // MARK: - Validation (for @Vector and @Spatial indexes)

    /// Validate fields with @Vector attributes
    ///
    /// This method is automatically generated by @Recordable macro when the record type
    /// contains fields with @Vector attributes.
    ///
    /// **Default Implementation**: No-op (for types without @Vector fields)
    ///
    /// - Throws: RecordLayerError.invalidArgument if validation fails
    func validateVectorFields() throws {
        // No-op: Types without @Vector fields do nothing
    }

    /// Validate fields with @Spatial attributes
    ///
    /// This method is automatically generated by @Recordable macro when the record type
    /// contains fields with @Spatial attributes.
    ///
    /// **Default Implementation**: No-op (for types without @Spatial fields)
    ///
    /// - Throws: RecordLayerError.invalidArgument if validation fails
    func validateSpatialFields() throws {
        // No-op: Types without @Spatial fields do nothing
    }

    /// Extract Range boundary value (auto-generated by @Recordable macro)
    ///
    /// This instance method is automatically generated by @Recordable macro for ALL types.
    /// For types without Range fields, the macro generates a method that throws fieldNotFound.
    /// For types with Range fields, the macro generates a method that extracts the specified boundary.
    ///
    /// **Default Implementation**: This should NEVER be called - the macro should always override it.
    /// If you see this error, the macro didn't generate the method (possible Swift compiler bug).
    ///
    /// - Parameters:
    ///   - fieldName: Range field name
    ///   - component: Boundary component (.lowerBound or .upperBound)
    /// - Returns: Array with boundary value as TupleElement (empty if nil Optional)
    /// - Throws: RecordLayerError.fieldNotFound if field doesn't exist or is not a Range
    func extractRangeBoundary(
        fieldName: String,
        component: RangeComponent
    ) throws -> [any TupleElement] {
        // NOTE: Due to a Swift limitation, the macro-generated method cannot override this default.
        // So we implement the logic using Reflection as a fallback.

        let mirror = Mirror(reflecting: self)
        guard let child = mirror.children.first(where: { $0.label == fieldName }) else {
            throw RecordLayerError.fieldNotFound(fieldName)
        }

        let value = child.value

        // Try to extract boundary using Mirror
        let valueMirror = Mirror(reflecting: value)

        // Handle Optional Range
        if valueMirror.displayStyle == .optional {
            guard let unwrapped = valueMirror.children.first?.value else {
                return []  // Optional is nil
            }
            return try extractBoundaryFromRange(unwrapped, component: component, fieldName: fieldName)
        }

        // Handle non-Optional Range
        return try extractBoundaryFromRange(value, component: component, fieldName: fieldName)
    }

    private func extractBoundaryFromRange(
        _ value: Any,
        component: RangeComponent,
        fieldName: String
    ) throws -> [any TupleElement] {
        let mirror = Mirror(reflecting: value)

        switch component {
        case .lowerBound:
            if let lowerBound = mirror.children.first(where: { $0.label == "lowerBound" })?.value as? any TupleElement {
                return [lowerBound]
            }
        case .upperBound:
            if let upperBound = mirror.children.first(where: { $0.label == "upperBound" })?.value as? any TupleElement {
                return [upperBound]
            }
        }

        throw RecordLayerError.fieldNotFound("Field '\(fieldName)' does not have \(component) component")
    }
}

// MARK: - Helper Functions

/// Convert Any value to TupleElement
private func convertToTupleElement(_ value: Any) -> (any TupleElement)? {
    switch value {
    case let v as String:
        return v
    case let v as Int:
        return Int64(v)
    case let v as Int32:
        return Int64(v)
    case let v as Int64:
        return v
    case let v as UInt:
        return Int64(v)
    case let v as UInt32:
        return Int64(v)
    case let v as Bool:
        return v
    case let v as Float:
        return v
    case let v as Double:
        return v
    case let v as Date:
        return v  // Date conforms to TupleElement via extension
    case let v as UUID:
        return v
    case let v as Data:
        return Array(v)
    default:
        return nil
    }
}

/// Convert Any value to array of TupleElements
private func convertToTupleElements(_ value: Any) -> [any TupleElement] {
    // Handle arrays
    if let array = value as? [Any] {
        return array.compactMap { convertToTupleElement($0) }
    }

    // Handle single values
    if let element = convertToTupleElement(value) {
        return [element]
    }

    return []
}
