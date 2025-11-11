import Foundation

public protocol CommitHook: Sendable {
    func execute(context: RecordContext) async throws
}

public struct ClosureCommitHook: CommitHook {
    private let closure: @Sendable (RecordContext) async throws -> Void

    public init(_ closure: @escaping @Sendable (RecordContext) async throws -> Void) {
        self.closure = closure
    }

    public func execute(context: RecordContext) async throws {
        try await closure(context)
    }
}
