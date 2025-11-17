import Testing

/// Test tags for categorizing tests by characteristics
extension Tag {
    /// Tests that take a long time to run (> 5 seconds) due to large data operations
    @Tag static var slow: Self

    /// Integration tests that test multiple components together
    @Tag static var integration: Self

    /// End-to-end tests that test the entire system
    @Tag static var e2e: Self

    /// Fast unit tests (< 1 second)
    @Tag static var unit: Self
}
