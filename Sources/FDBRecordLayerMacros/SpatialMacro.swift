import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

/// Implementation of the @Spatial macro
///
/// This attached property macro generates spatial index metadata for Z-order curve spatial indexing.
/// It validates parameters and marks properties for index generation by @Recordable.
///
/// Usage:
/// ```swift
/// @Recordable
/// struct Restaurant {
///     #PrimaryKey<Restaurant>([\.restaurantID])
///
///     @Spatial
///     var location: GeoCoordinate
///
///     var restaurantID: Int64
/// }
/// ```
///
/// **3D Usage**:
/// ```swift
/// @Recordable
/// struct Drone {
///     #PrimaryKey<Drone>([\.droneID])
///
///     @Spatial(type: .geo3D)
///     var position: GeoCoordinate
///
///     var droneID: Int64
/// }
/// ```
///
/// **Parameters**:
/// - `type`: Spatial type (default: `.geo`)
///   - `.geo`: 2D geographic coordinates (latitude, longitude)
///   - `.geo3D`: 3D geographic coordinates (latitude, longitude, altitude)
///   - `.cartesian`: 2D Cartesian coordinates (x, y)
///   - `.cartesian3D`: 3D Cartesian coordinates (x, y, z)
///
/// **Note**: @Spatial is an attached peer macro that generates no peer declarations.
/// The @Recordable macro detects @Spatial attributes and generates IndexDefinitions with type: .spatial.
public struct SpatialMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // 1. Validate that @Spatial is applied to a property
        guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: SpatialMacroDiagnostic.notAppliedToProperty
                )
            )
            return []
        }

        // 2. Extract property name
        guard let binding = varDecl.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: varDecl,
                    message: SpatialMacroDiagnostic.invalidPropertyDeclaration
                )
            )
            return []
        }

        let propertyName = pattern.identifier.text

        // 3. Validate parameters
        try validateSpatialParameters(node: node, propertyName: propertyName, context: context)

        // 4. @attached(peer) returns empty (metadata collected by @Recordable)
        // The @Recordable macro will scan all properties for @Spatial attributes
        // and generate IndexDefinitions with type: .spatial
        return []
    }

    private static func validateSpatialParameters(
        node: AttributeSyntax,
        propertyName: String,
        context: some MacroExpansionContext
    ) throws {
        // Extract arguments from @Spatial(type: .geo)
        // If no arguments, use defaults (type: .geo)
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
            // No arguments is valid (@Spatial with all defaults)
            return
        }

        // Validate type: parameter if present (optional, default: .geo)
        if let typeArg = arguments.first(where: { $0.label?.text == "type" }) {
            // type: must be a member access expression (e.g., .geo, .geo3D, .cartesian, .cartesian3D)
            guard typeArg.expression.is(MemberAccessExprSyntax.self) else {
                context.diagnose(
                    Diagnostic(
                        node: typeArg,
                        message: SpatialMacroDiagnostic.invalidType
                    )
                )
                return
            }
        }
    }
}

// MARK: - Diagnostics

enum SpatialMacroDiagnostic {
    case notAppliedToProperty
    case invalidPropertyDeclaration
    case invalidType
}

extension SpatialMacroDiagnostic: DiagnosticMessage {
    var message: String {
        switch self {
        case .notAppliedToProperty:
            return """
            @Spatial can only be applied to properties
            Usage: @Spatial var location: GeoCoordinate
            """

        case .invalidPropertyDeclaration:
            return """
            @Spatial requires a valid property declaration
            Usage: @Spatial var location: GeoCoordinate
            """

        case .invalidType:
            return """
            'type:' parameter must be a SpatialType enum value
            Usage: @Spatial(type: .geo) var location: GeoCoordinate

            Valid types:
            - .geo (default): 2D geographic coordinates (latitude, longitude)
            - .geo3D: 3D geographic coordinates (latitude, longitude, altitude)
            - .cartesian: 2D Cartesian coordinates (x, y)
            - .cartesian3D: 3D Cartesian coordinates (x, y, z)

            Examples:
            @Spatial(type: .geo) var location: GeoCoordinate         // 2D geographic
            @Spatial(type: .geo3D) var position: GeoCoordinate       // 3D geographic
            @Spatial(type: .cartesian) var point: CartesianCoord     // 2D Cartesian
            @Spatial(type: .cartesian3D) var point3D: CartesianCoord // 3D Cartesian
            """
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "FDBRecordLayerMacros", id: "SpatialMacro")
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
