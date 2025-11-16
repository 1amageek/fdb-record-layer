import Foundation
import FoundationDB
import FDBRecordCore

// MARK: - Re-export Core Types

// Re-export Recordable protocol from FDBRecordCore
@_exported import struct FDBRecordCore.IndexDefinition
@_exported import struct FDBRecordCore.VectorIndexOptions
@_exported import struct FDBRecordCore.SpatialIndexOptions
@_exported import enum FDBRecordCore.VectorMetric
@_exported import enum FDBRecordCore.SpatialType
@_exported import enum FDBRecordCore.IndexDefinitionType
@_exported import enum FDBRecordCore.IndexDefinitionScope
@_exported import enum FDBRecordCore.RangeComponent
@_exported import enum FDBRecordCore.BoundaryType
@_exported import struct FDBRecordCore.EnumMetadata

/// Re-export Recordable protocol from FDBRecordCore
///
/// The actual protocol definition is in FDBRecordCore (FDB-independent).
/// This file adds FDB-specific extensions via RecordableExtensions.swift.
public typealias Recordable = FDBRecordCore.Recordable

// Note: FDB-specific methods (extractField, extractPrimaryKey, reconstruct, etc.)
// are defined in RecordableExtensions.swift as extensions to Recordable protocol.
