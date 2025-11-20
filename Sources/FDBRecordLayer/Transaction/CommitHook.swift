import Foundation

internal protocol CommitHook: Sendable {
    func execute(context: TransactionContext) async throws
}

internal struct ClosureCommitHook: CommitHook {
    private let closure: @Sendable (TransactionContext) async throws -> Void

    internal init(_ closure: @escaping @Sendable (TransactionContext) async throws -> Void) {
        self.closure = closure
    }

    internal func execute(context: TransactionContext) async throws {
        try await closure(context)
    }
}
