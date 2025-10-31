import Foundation
import FoundationDB
import Logging

/// Manages index state transitions with validation
///
/// IndexStateManager enforces the following transition rules:
/// - DISABLED → WRITE_ONLY: enableIndex()
/// - WRITE_ONLY → READABLE: markReadable()
/// - Any state → DISABLED: disableIndex()
///
/// Thread-safe through Actor isolation.
///
/// State reads are performed within FoundationDB transactions to ensure
/// consistency. No application-level caching is used, relying on
/// FoundationDB's built-in read-your-writes and transaction optimizations.
public actor IndexStateManager {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let logger: Logger

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.indexstate")
    }

    // MARK: - State Queries

    /// Get the current state of an index
    ///
    /// Creates a new transaction to read the state. For consistency within
    /// an existing transaction, use getState(indexName:context:) instead.
    ///
    /// - Parameter indexName: Name of the index
    /// - Returns: Current IndexState
    /// - Throws: RecordLayerError if state value is invalid
    public func getState(indexName: String) async throws -> IndexState {
        let state = try await database.withRecordContext { [subspace] context in
            let transaction = context.getTransaction()
            let stateKey = Self.makeStateKey(for: indexName, in: subspace)

            guard let bytes = try await transaction.getValue(for: stateKey),
                  let stateValue = bytes.first else {
                // Default: new indexes start as DISABLED
                return IndexState.disabled
            }

            guard let state = IndexState(rawValue: stateValue) else {
                throw RecordLayerError.invalidIndexState(stateValue)
            }

            return state
        }

        logger.debug("Index '\(indexName)' state: \(state)")
        return state
    }

    /// Get the current state of an index within a transaction context
    ///
    /// Use this when you need to read index state within an existing transaction
    /// to ensure consistency with other operations in the same transaction.
    ///
    /// - Parameters:
    ///   - indexName: Name of the index
    ///   - context: The transaction context to use
    /// - Returns: Current IndexState
    /// - Throws: RecordLayerError if state value is invalid
    public func getState(indexName: String, context: RecordContext) async throws -> IndexState {
        let transaction = context.getTransaction()
        let stateKey = Self.makeStateKey(for: indexName, in: subspace)

        guard let bytes = try await transaction.getValue(for: stateKey),
              let stateValue = bytes.first else {
            // Default: new indexes start as DISABLED
            return IndexState.disabled
        }

        guard let state = IndexState(rawValue: stateValue) else {
            throw RecordLayerError.invalidIndexState(stateValue)
        }

        return state
    }

    // MARK: - State Transitions

    /// Enable an index (transition to WRITE_ONLY state)
    ///
    /// This sets the index to WRITE_ONLY state, meaning:
    /// - New writes will maintain the index
    /// - Queries will not use the index yet
    /// - Background index building can proceed
    ///
    /// - Parameter indexName: Name of the index
    /// - Throws: RecordLayerError.invalidStateTransition if not in DISABLED state
    public func enableIndex(indexName: String) async throws {
        try await database.withRecordContext { [subspace, logger] context in
            let transaction = context.getTransaction()
            let stateKey = Self.makeStateKey(for: indexName, in: subspace)

            // Read current state within transaction
            let currentState: IndexState
            if let bytes = try await transaction.getValue(for: stateKey),
               let stateValue = bytes.first,
               let state = IndexState(rawValue: stateValue) {
                currentState = state
            } else {
                currentState = .disabled
            }

            // Validate transition: only from DISABLED
            guard currentState == .disabled else {
                throw RecordLayerError.invalidStateTransition(
                    from: currentState,
                    to: .writeOnly,
                    index: indexName,
                    reason: "Index must be DISABLED before enabling"
                )
            }

            // Write new state
            transaction.setValue([IndexState.writeOnly.rawValue], for: stateKey)

            logger.info("Enabled index '\(indexName)': \(currentState) → writeOnly")
        }
    }

    /// Mark an index as readable (transition to READABLE state)
    ///
    /// This should only be called after index building is complete.
    ///
    /// - Parameter indexName: Name of the index
    /// - Throws: RecordLayerError.invalidStateTransition if not in WRITE_ONLY state
    public func markReadable(indexName: String) async throws {
        try await database.withRecordContext { [subspace, logger] context in
            let transaction = context.getTransaction()
            let stateKey = Self.makeStateKey(for: indexName, in: subspace)

            // Read current state within transaction
            let currentState: IndexState
            if let bytes = try await transaction.getValue(for: stateKey),
               let stateValue = bytes.first,
               let state = IndexState(rawValue: stateValue) {
                currentState = state
            } else {
                currentState = .disabled
            }

            // Validate transition: only from WRITE_ONLY
            guard currentState == .writeOnly else {
                throw RecordLayerError.invalidStateTransition(
                    from: currentState,
                    to: .readable,
                    index: indexName,
                    reason: "Index must be in WRITE_ONLY state before marking readable"
                )
            }

            // Write new state
            transaction.setValue([IndexState.readable.rawValue], for: stateKey)

            logger.info("Marked index '\(indexName)' as readable: \(currentState) → readable")
        }
    }

    /// Disable an index (transition to DISABLED state)
    ///
    /// This can be called from any state.
    ///
    /// - Parameter indexName: Name of the index
    public func disableIndex(indexName: String) async throws {
        try await database.withRecordContext { [subspace, logger] context in
            let transaction = context.getTransaction()
            let stateKey = Self.makeStateKey(for: indexName, in: subspace)

            // Read current state within transaction (for logging)
            let currentState: IndexState
            if let bytes = try await transaction.getValue(for: stateKey),
               let stateValue = bytes.first,
               let state = IndexState(rawValue: stateValue) {
                currentState = state
            } else {
                currentState = .disabled
            }

            // Write new state (no validation - can disable from any state)
            transaction.setValue([IndexState.disabled.rawValue], for: stateKey)

            logger.info("Disabled index '\(indexName)': \(currentState) → disabled")
        }
    }

    // MARK: - Batch Operations

    /// Get states for multiple indexes efficiently
    ///
    /// Creates a new transaction to read states. For consistency within
    /// an existing transaction, use getStates(indexNames:context:) instead.
    ///
    /// - Parameter indexNames: List of index names
    /// - Returns: Dictionary mapping index names to states
    public func getStates(indexNames: [String]) async throws -> [String: IndexState] {
        return try await database.withRecordContext { [subspace] context in
            let transaction = context.getTransaction()
            let stateSubspace = subspace.subspace(RecordStoreKeyspace.indexState.rawValue)
            var states: [String: IndexState] = [:]

            for indexName in indexNames {
                let stateKey = stateSubspace.pack(Tuple(indexName))

                guard let bytes = try await transaction.getValue(for: stateKey),
                      let stateValue = bytes.first,
                      let state = IndexState(rawValue: stateValue) else {
                    states[indexName] = .disabled
                    continue
                }

                states[indexName] = state
            }

            return states
        }
    }

    /// Get states for multiple indexes within a transaction context
    ///
    /// Use this when you need to read multiple index states within an existing
    /// transaction to ensure consistency with other operations in the same transaction.
    ///
    /// - Parameters:
    ///   - indexNames: List of index names
    ///   - context: The transaction context to use
    /// - Returns: Dictionary mapping index names to states
    public func getStates(indexNames: [String], context: RecordContext) async throws -> [String: IndexState] {
        let transaction = context.getTransaction()
        let stateSubspace = subspace.subspace(RecordStoreKeyspace.indexState.rawValue)
        var states: [String: IndexState] = [:]

        for indexName in indexNames {
            let stateKey = stateSubspace.pack(Tuple(indexName))

            guard let bytes = try await transaction.getValue(for: stateKey),
                  let stateValue = bytes.first,
                  let state = IndexState(rawValue: stateValue) else {
                states[indexName] = .disabled
                continue
            }

            states[indexName] = state
        }

        return states
    }

    // MARK: - Private Helpers

    private static func makeStateKey(for indexName: String, in subspace: Subspace) -> FDB.Bytes {
        let stateSubspace = subspace.subspace(RecordStoreKeyspace.indexState.rawValue)
        return stateSubspace.pack(Tuple(indexName))
    }
}
