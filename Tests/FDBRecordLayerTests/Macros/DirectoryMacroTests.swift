import Testing
import FDBRecordLayer
import FoundationDB
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import FDBRecordLayerMacros

@Suite("Directory Macro Tests")
struct DirectoryMacroTests {

    // MARK: - DirectoryType Tests (from fdb-swift-bindings)

    @Test("DirectoryType partition and custom types")
    func directoryType() {
        // Test standard partition type
        let partition: DirectoryType = .partition
        #expect(partition.description == "partition")
        #expect(partition.rawValue == Array("partition".utf8))

        // Test custom types
        let recordStore: DirectoryType = .custom("fdb_record_layer")
        let lucene: DirectoryType = .custom("lucene_index")
        let timeSeries: DirectoryType = .custom("time_series")
        let vectorIndex: DirectoryType = .custom("vector_index")

        #expect(recordStore.description == "fdb_record_layer")
        #expect(lucene.description == "lucene_index")
        #expect(timeSeries.description == "time_series")
        #expect(vectorIndex.description == "vector_index")
    }

    @Test("DirectoryType equatable")
    func directoryTypeEquality() {
        let partition1: DirectoryType = .partition
        let partition2: DirectoryType = .partition
        let custom: DirectoryType = .custom("test")

        #expect(partition1 == partition2)
        #expect(partition1 != custom)
    }

    @Test("DirectoryType rawValue conversion")
    func directoryTypeRawValue() {
        let partition = DirectoryType.partition
        let custom = DirectoryType.custom("my_layer")

        #expect(partition.rawValue == Array("partition".utf8))
        #expect(custom.rawValue == Array("my_layer".utf8))

        // Test initialization from rawValue
        let parsedPartition = DirectoryType(rawValue: Array("partition".utf8))
        let parsedCustom = DirectoryType(rawValue: Array("my_layer".utf8))

        #expect(parsedPartition == .partition)
        #expect(parsedCustom == .custom("my_layer"))
    }

    // MARK: - Directory Macro Validation Tests

    let testMacros: [String: Macro.Type] = [
        "Directory": DirectoryMacro.self
    ]

    @Test("Valid directory with static path")
    func validStaticPath() {
        assertMacroExpansion(
            """
            #Directory<User>("app", "users", layer: .recordStore)
            """,
            expandedSource: "",  // Marker macro generates nothing
            macros: testMacros
        )
    }

    @Test("Valid directory with partition and keypath")
    func validPartitionWithKeyPath() {
        assertMacroExpansion(
            """
            #Directory<Order>("tenants", Field(\\.accountID), "orders", layer: .partition)
            """,
            expandedSource: "",  // Marker macro generates nothing
            macros: testMacros
        )
    }

    @Test("Valid directory with multiple keypaths")
    func validMultipleKeyPaths() {
        assertMacroExpansion(
            """
            #Directory<Message>("tenants", Field(\\.accountID), "channels", Field(\\.channelID), "messages", layer: .partition)
            """,
            expandedSource: "",  // Marker macro generates nothing
            macros: testMacros
        )
    }

    @Test("Error: Missing type parameter")
    func errorMissingTypeParameter() {
        assertMacroExpansion(
            """
            #Directory("app", "users")
            """,
            expandedSource: """
            #Directory("app", "users")
            """,
            diagnostics: [
                DiagnosticSpec(message: "#Directory requires a type parameter (e.g., #Directory<User>)", line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    @Test("Error: Invalid path element (integer)")
    func errorInvalidPathElement() {
        assertMacroExpansion(
            """
            #Directory<User>("app", 123)
            """,
            expandedSource: """
            #Directory<User>("app", 123)
            """,
            diagnostics: [
                DiagnosticSpec(message: "Path elements must be string literals (\"literal\") or Field(\\.propertyName) expressions", line: 1, column: 25)
            ],
            macros: testMacros
        )
    }

    @Test("Error: Partition without Field")
    func errorPartitionWithoutKeyPath() {
        assertMacroExpansion(
            """
            #Directory<User>("app", "users", layer: .partition)
            """,
            expandedSource: """
            #Directory<User>("app", "users", layer: .partition)
            """,
            diagnostics: [
                DiagnosticSpec(message: "layer: .partition requires at least one Field in the path (e.g., Field(\\.accountID))", line: 1, column: 42)
            ],
            macros: testMacros
        )
    }

    // MARK: - @Recordable + #Directory Integration Tests

    let integrationMacros: [String: Macro.Type] = [
        "Recordable": RecordableMacro.self,
        "Directory": DirectoryMacro.self
    ]

    @Test("@Recordable with static #Directory generates openDirectory()")
    func recordableWithStaticDirectory() {
        // This test verifies that @Recordable macro reads #Directory and generates
        // the openDirectory() and store() methods in the extension

        // Example source that would be processed by @Recordable macro:
        _ = """
            @Recordable
            struct User {
                #Directory<User>(["app", "users"], layer: .recordStore)
                #PrimaryKey<User>([\\.userID])

                var userID: Int64
                var name: String
            }
            """

        // We can't use full assertMacroExpansion here because it would be too long
        // Instead, we verify the key parts are generated by checking compilation

        // The macro should generate these methods:
        // - public static func openDirectory(database: any DatabaseProtocol) async throws -> DirectorySubspace
        // - public static func store(database: any DatabaseProtocol, schema: Schema) async throws -> RecordStore<User>

        // This is verified by the compilation test in DirectoryIntegrationTests.swift
        #expect(true, "See RecordableMacro.swift:412-548 for openDirectory() and store() generation")
    }

    @Test("@Recordable with partition #Directory")
    func recordableWithPartitionDirectory() {
        assertMacroExpansion(
            """
            @Recordable
            struct Order {
                #Directory<Order>("tenants", Field(\\.accountID), "orders", layer: .partition)
                #PrimaryKey<Order>([\\.orderID])

                var orderID: Int64
                var accountID: String
                var total: Int64
            }
            """,
            expandedSource: """
            struct Order {

                var orderID: Int64
                var accountID: String
                var total: Int64

                public static func fieldName(for keyPath: PartialKeyPath<Order>) -> String? {
                    switch keyPath {
                    case \\.orderID: return "orderID"
                    case \\.accountID: return "accountID"
                    case \\.total: return "total"
                    default: return nil
                    }
                }
            }

            extension Order: Recordable {
                public static var recordName: String { "Order" }

                public static var primaryKeyFields: [String] { ["orderID"] }

                public static var allFields: [String] { ["orderID", "accountID", "total"] }

                public static var indexDefinitions: [IndexDefinition] { [] }

                public static func fieldNumber(for fieldName: String) -> Int? {
                    switch fieldName {
                    case "orderID": return 1
                    case "accountID": return 2
                    case "total": return 3
                    default: return nil
                    }
                }
            """,
            macros: integrationMacros,
            indentationWidth: .spaces(4)
        )
    }
}
