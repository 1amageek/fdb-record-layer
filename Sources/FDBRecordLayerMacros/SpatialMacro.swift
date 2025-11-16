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
/// **New KeyPath-based syntax** (supports nested structures):
/// ```swift
/// @Recordable
/// struct Restaurant {
///     #PrimaryKey<Restaurant>([\.restaurantID])
///
///     @Spatial(
///         type: .geo(
///             latitude: \.address.location.latitude,
///             longitude: \.address.location.longitude
///         )
///     )
///     var address: Address
///
///     var restaurantID: Int64
/// }
///
/// struct Address: Codable, Sendable {
///     var street: String
///     var location: Location
/// }
///
/// struct Location: Codable, Sendable {
///     var latitude: Double
///     var longitude: Double
/// }
/// ```
///
/// **3D Usage**:
/// ```swift
/// @Recordable
/// struct Drone {
///     #PrimaryKey<Drone>([\.droneID])
///
///     @Spatial(
///         type: .geo3D(
///             latitude: \.position.lat,
///             longitude: \.position.lon,
///             altitude: \.position.height
///         )
///     )
///     var position: Position
///
///     var droneID: Int64
/// }
/// ```
///
/// **Supported Types**:
/// - `.geo(latitude: KeyPath, longitude: KeyPath)`: 2D geographic
/// - `.geo3D(latitude: KeyPath, longitude: KeyPath, altitude: KeyPath)`: 3D geographic
/// - `.cartesian(x: KeyPath, y: KeyPath)`: 2D Cartesian
/// - `.cartesian3D(x: KeyPath, y: KeyPath, z: KeyPath)`: 3D Cartesian
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
        // Extract arguments from @Spatial(type: .geo(...))
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: SpatialMacroDiagnostic.missingTypeParameter
                )
            )
            return
        }

        // Validate type: parameter (required with new KeyPath syntax)
        guard let typeArg = arguments.first(where: { $0.label?.text == "type" }) else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: SpatialMacroDiagnostic.missingTypeParameter
                )
            )
            return
        }

        // type: must be a function call expression (e.g., .geo(latitude: \.x, longitude: \.y))
        guard let funcCall = typeArg.expression.as(FunctionCallExprSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: typeArg,
                    message: SpatialMacroDiagnostic.invalidType
                )
            )
            return
        }

        // Validate callee is a member access (.geo, .geo3D, .cartesian, .cartesian3D)
        guard let callee = funcCall.calledExpression.as(MemberAccessExprSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: funcCall,
                    message: SpatialMacroDiagnostic.invalidType
                )
            )
            return
        }

        // Extract type name from member access
        let typeName = callee.declName.baseName.text

        // Validate spatial type and argument count
        try validateSpatialTypeArguments(
            typeName: typeName,
            arguments: funcCall.arguments,
            node: funcCall,
            context: context
        )
    }

    private static func validateSpatialTypeArguments(
        typeName: String,
        arguments: LabeledExprListSyntax,
        node: FunctionCallExprSyntax,
        context: some MacroExpansionContext
    ) throws {
        switch typeName {
        case "geo":
            // Requires: latitude:, longitude: (level: and altitudeRange: are optional)
            guard arguments.contains(where: { $0.label?.text == "latitude" }),
                  arguments.contains(where: { $0.label?.text == "longitude" }) else {
                context.diagnose(
                    Diagnostic(
                        node: node,
                        message: SpatialMacroDiagnostic.invalidGeoArguments
                    )
                )
                return
            }

        case "geo3D":
            // Requires: latitude:, longitude:, altitude: (level: and altitudeRange: are optional)
            guard arguments.contains(where: { $0.label?.text == "latitude" }),
                  arguments.contains(where: { $0.label?.text == "longitude" }),
                  arguments.contains(where: { $0.label?.text == "altitude" }) else {
                context.diagnose(
                    Diagnostic(
                        node: node,
                        message: SpatialMacroDiagnostic.invalidGeo3DArguments
                    )
                )
                return
            }

        case "cartesian":
            // Requires: x:, y: (level: is optional)
            guard arguments.contains(where: { $0.label?.text == "x" }),
                  arguments.contains(where: { $0.label?.text == "y" }) else {
                context.diagnose(
                    Diagnostic(
                        node: node,
                        message: SpatialMacroDiagnostic.invalidCartesianArguments
                    )
                )
                return
            }

        case "cartesian3D":
            // Requires: x:, y:, z: (level: and altitudeRange: are optional)
            guard arguments.contains(where: { $0.label?.text == "x" }),
                  arguments.contains(where: { $0.label?.text == "y" }),
                  arguments.contains(where: { $0.label?.text == "z" }) else {
                context.diagnose(
                    Diagnostic(
                        node: node,
                        message: SpatialMacroDiagnostic.invalidCartesian3DArguments
                    )
                )
                return
            }

        default:
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: SpatialMacroDiagnostic.unknownSpatialType(typeName)
                )
            )
        }

        // Validate coordinate arguments are KeyPath expressions (skip level/altitudeRange)
        // level: is Int, altitudeRange: is ClosedRange<Double> - these are not KeyPaths
        let nonKeyPathParams = ["level", "altitudeRange"]
        for arg in arguments {
            // Skip validation for known non-KeyPath parameters
            if let label = arg.label?.text, nonKeyPathParams.contains(label) {
                continue
            }

            // Coordinate parameters (latitude, longitude, altitude, x, y, z) must be KeyPaths
            guard arg.expression.is(KeyPathExprSyntax.self) else {
                context.diagnose(
                    Diagnostic(
                        node: arg,
                        message: SpatialMacroDiagnostic.argumentMustBeKeyPath(arg.label?.text ?? "unknown")
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
    case missingTypeParameter
    case invalidType
    case invalidGeoArguments
    case invalidGeo3DArguments
    case invalidCartesianArguments
    case invalidCartesian3DArguments
    case unknownSpatialType(String)
    case argumentMustBeKeyPath(String)
}

extension SpatialMacroDiagnostic: DiagnosticMessage {
    var message: String {
        switch self {
        case .notAppliedToProperty:
            return """
            @Spatial can only be applied to properties

            Usage:
            @Spatial(type: .geo(latitude: \\.lat, longitude: \\.lon))
            var location: Location
            """

        case .invalidPropertyDeclaration:
            return """
            @Spatial requires a valid property declaration

            Usage:
            @Spatial(type: .geo(latitude: \\.lat, longitude: \\.lon))
            var location: Location
            """

        case .missingTypeParameter:
            return """
            @Spatial requires 'type:' parameter with KeyPath arguments

            Valid types:
            - .geo(latitude: KeyPath, longitude: KeyPath)
            - .geo3D(latitude: KeyPath, longitude: KeyPath, altitude: KeyPath)
            - .cartesian(x: KeyPath, y: KeyPath)
            - .cartesian3D(x: KeyPath, y: KeyPath, z: KeyPath)

            Examples:
            @Spatial(type: .geo(latitude: \\.lat, longitude: \\.lon))
            var location: Location

            @Spatial(type: .geo(latitude: \\.address.location.latitude, longitude: \\.address.location.longitude))
            var address: Address
            """

        case .invalidType:
            return """
            'type:' parameter must be a SpatialType function call with KeyPath arguments

            Valid types:
            - .geo(latitude: KeyPath, longitude: KeyPath)
            - .geo3D(latitude: KeyPath, longitude: KeyPath, altitude: KeyPath)
            - .cartesian(x: KeyPath, y: KeyPath)
            - .cartesian3D(x: KeyPath, y: KeyPath, z: KeyPath)

            Examples:
            @Spatial(type: .geo(latitude: \\.lat, longitude: \\.lon))
            @Spatial(type: .geo3D(latitude: \\.lat, longitude: \\.lon, altitude: \\.alt))
            @Spatial(type: .cartesian(x: \\.x, y: \\.y))
            @Spatial(type: .cartesian3D(x: \\.x, y: \\.y, z: \\.z))
            """

        case .invalidGeoArguments:
            return """
            .geo requires exactly 2 labeled arguments: latitude: and longitude:

            Usage:
            @Spatial(type: .geo(latitude: \\.lat, longitude: \\.lon))

            Supports nested KeyPaths:
            @Spatial(type: .geo(latitude: \\.address.location.latitude, longitude: \\.address.location.longitude))
            """

        case .invalidGeo3DArguments:
            return """
            .geo3D requires exactly 3 labeled arguments: latitude:, longitude:, and altitude:

            Usage:
            @Spatial(type: .geo3D(latitude: \\.lat, longitude: \\.lon, altitude: \\.alt))

            Supports nested KeyPaths:
            @Spatial(type: .geo3D(latitude: \\.position.lat, longitude: \\.position.lon, altitude: \\.position.height))
            """

        case .invalidCartesianArguments:
            return """
            .cartesian requires exactly 2 labeled arguments: x: and y:

            Usage:
            @Spatial(type: .cartesian(x: \\.x, y: \\.y))

            Supports nested KeyPaths:
            @Spatial(type: .cartesian(x: \\.point.x, y: \\.point.y))
            """

        case .invalidCartesian3DArguments:
            return """
            .cartesian3D requires exactly 3 labeled arguments: x:, y:, and z:

            Usage:
            @Spatial(type: .cartesian3D(x: \\.x, y: \\.y, z: \\.z))

            Supports nested KeyPaths:
            @Spatial(type: .cartesian3D(x: \\.position.x, y: \\.position.y, z: \\.position.z))
            """

        case .unknownSpatialType(let typeName):
            return """
            Unknown spatial type: '\(typeName)'

            Valid types:
            - .geo(latitude: KeyPath, longitude: KeyPath)
            - .geo3D(latitude: KeyPath, longitude: KeyPath, altitude: KeyPath)
            - .cartesian(x: KeyPath, y: KeyPath)
            - .cartesian3D(x: KeyPath, y: KeyPath, z: KeyPath)
            """

        case .argumentMustBeKeyPath(let argName):
            return """
            Argument '\(argName)' must be a KeyPath expression

            Valid KeyPath syntax:
            - Simple: \\.latitude
            - Nested: \\.address.location.latitude
            - Deep: \\.data.nested.field.value

            Example:
            @Spatial(type: .geo(latitude: \\.lat, longitude: \\.lon))
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
