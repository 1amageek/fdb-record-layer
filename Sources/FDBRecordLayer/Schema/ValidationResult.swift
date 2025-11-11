import Foundation

public struct ValidationResult: Sendable {
    public let isValid: Bool
    public let errors: [EvolutionError]
    public let warnings: [String]

    public init(isValid: Bool, errors: [EvolutionError], warnings: [String]) {
        self.isValid = isValid
        self.errors = errors
        self.warnings = warnings
    }

    public static let valid = ValidationResult(isValid: true, errors: [], warnings: [])

    public func addError(_ error: EvolutionError) -> ValidationResult {
        ValidationResult(
            isValid: false,
            errors: errors + [error],
            warnings: warnings
        )
    }

    public func addWarning(_ warning: String) -> ValidationResult {
        ValidationResult(
            isValid: isValid,
            errors: errors,
            warnings: warnings + [warning]
        )
    }
}
