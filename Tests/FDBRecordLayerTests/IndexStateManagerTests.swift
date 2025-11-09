import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Tests for IndexStateManager
///
/// NOTE: Integration tests require a running FoundationDB instance
/// Unit tests can run without FDB
@Suite("IndexStateManager Tests")
struct IndexStateManagerTests {

    // MARK: - Initialization

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - State Queries (Integration Tests)

    @Test("New index returns disabled state", .disabled("Requires running FoundationDB instance"))
    func newIndexReturnsDisabled() async throws {
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_index_state".utf8))
        let manager = IndexStateManager(database: db, subspace: subspace)

        // New index should default to disabled
        let state = try await manager.state(of: "new_index")
        #expect(state == .disabled)

        // Cleanup
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("Enable transitions index from disabled to writeOnly", .disabled("Requires running FoundationDB instance"))
    func enableTransition() async throws {
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_enable_\(UUID().uuidString)".utf8))
        let manager = IndexStateManager(database: db, subspace: subspace)

        // Verify initial state
        let initialState = try await manager.state(of: "test_index")
        #expect(initialState == .disabled)

        // Enable the index
        try await manager.enable("test_index")

        // Verify transition to writeOnly
        let newState = try await manager.state(of: "test_index")
        #expect(newState == .writeOnly)

        // Cleanup
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("MakeReadable transitions index from writeOnly to readable", .disabled("Requires running FoundationDB instance"))
    func makeReadableTransition() async throws {
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_readable_\(UUID().uuidString)".utf8))
        let manager = IndexStateManager(database: db, subspace: subspace)

        // Enable first (disabled → writeOnly)
        try await manager.enable("test_index")

        // Verify writeOnly state
        let writeOnlyState = try await manager.state(of: "test_index")
        #expect(writeOnlyState == .writeOnly)

        // Make readable (writeOnly → readable)
        try await manager.makeReadable("test_index")

        // Verify readable state
        let readableState = try await manager.state(of: "test_index")
        #expect(readableState == .readable)

        // Cleanup
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("Disable transitions index from any state to disabled", .disabled("Requires running FoundationDB instance"))
    func disableFromAnyState() async throws {
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_disable_\(UUID().uuidString)".utf8))
        let manager = IndexStateManager(database: db, subspace: subspace)

        // Test: disabled → enabled → disabled
        try await manager.enable("test_index")
        try await manager.disable("test_index")
        let state1 = try await manager.state(of: "test_index")
        #expect(state1 == .disabled)

        // Test: disabled → enabled → readable → disabled
        try await manager.enable("test_index")
        try await manager.makeReadable("test_index")
        try await manager.disable("test_index")
        let state2 = try await manager.state(of: "test_index")
        #expect(state2 == .disabled)

        // Cleanup
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("Invalid transition from disabled to readable throws error", .disabled("Requires running FoundationDB instance"))
    func invalidTransitionThrowsError() async throws {
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_invalid_\(UUID().uuidString)".utf8))
        let manager = IndexStateManager(database: db, subspace: subspace)

        // Attempting disabled → readable should throw
        await #expect(throws: (any Error).self) {
            try await manager.makeReadable("test_index")
        }

        // Cleanup
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("State read within transaction context is consistent", .disabled("Requires running FoundationDB instance"))
    func stateReadConsistency() async throws {
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_consistency_\(UUID().uuidString)".utf8))
        let manager = IndexStateManager(database: db, subspace: subspace)

        try await db.withRecordContext { context in
            // Read initial state within transaction
            let state1 = try await manager.state(of: "test_index", context: context)
            #expect(state1 == .disabled)

            // Enable in separate transaction
            try await manager.enable("test_index")

            // Read again in same transaction (should still see old value due to snapshot isolation)
            let state2 = try await manager.state(of: "test_index", context: context)
            #expect(state2 == .disabled)
        }

        // Read in new transaction (should see new value)
        let state3 = try await manager.state(of: "test_index")
        #expect(state3 == .writeOnly)

        // Cleanup
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("Batch states operation returns multiple index states", .disabled("Requires running FoundationDB instance"))
    func batchStatesOperation() async throws {
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_batch_\(UUID().uuidString)".utf8))
        let manager = IndexStateManager(database: db, subspace: subspace)

        // Set up different states
        try await manager.enable("index1")
        try await manager.enable("index2")
        try await manager.makeReadable("index2")
        // index3 remains disabled

        // Batch read states
        let states = try await manager.states(of: ["index1", "index2", "index3"])

        #expect(states["index1"] == .writeOnly)
        #expect(states["index2"] == .readable)
        #expect(states["index3"] == .disabled)

        // Cleanup
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - Unit Tests (No FDB Required)

    @Test("IndexState description returns correct string")
    func indexStateDescription() {
        #expect(IndexState.readable.description == "readable")
        #expect(IndexState.disabled.description == "disabled")
        #expect(IndexState.writeOnly.description == "writeOnly")
    }

    @Test("IndexState isReadable property returns correct value")
    func indexStateIsReadable() {
        #expect(IndexState.readable.isReadable == true)
        #expect(IndexState.disabled.isReadable == false)
        #expect(IndexState.writeOnly.isReadable == false)
    }

    @Test("IndexState shouldMaintain property returns correct value")
    func indexStateShouldMaintain() {
        #expect(IndexState.readable.shouldMaintain == true)
        #expect(IndexState.disabled.shouldMaintain == false)
        #expect(IndexState.writeOnly.shouldMaintain == true)
    }

    @Test("IndexState has three cases", arguments: [
        IndexState.readable,
        IndexState.disabled,
        IndexState.writeOnly
    ])
    func indexStateAllCases(state: IndexState) {
        // Verify all states are valid
        #expect(state.rawValue >= 0)
        #expect(state.rawValue <= 2)
    }
}

// MARK: - Future Integration Tests

/*
@Suite("IndexStateManager Integration Tests", .disabled("Requires FoundationDB"))
struct IndexStateManagerIntegrationTests {

    @Test("Full index lifecycle: disabled → writeOnly → readable → disabled")
    func fullIndexLifecycle() async throws {
        // Would test complete lifecycle with real FDB
    }

    @Test("Concurrent state transitions are handled correctly")
    func concurrentStateTransitions() async throws {
        // Would test race conditions with real FDB
    }
}
*/
