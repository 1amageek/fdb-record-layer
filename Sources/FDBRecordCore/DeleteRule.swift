import Foundation

/// Defines the behavior when a related record is deleted
///
/// These rules determine what happens to dependent records when their parent record is deleted.
public enum DeleteRule: Sendable {
    /// Do nothing when the parent record is deleted
    ///
    /// The dependent records remain unchanged. This can lead to orphaned records
    /// if not handled carefully.
    case noAction

    /// Delete all dependent records when the parent record is deleted
    ///
    /// This is useful for parent-child relationships where children should not exist
    /// without their parent (e.g., deleting a User also deletes all their Orders).
    case cascade

    /// Set the foreign key to null when the parent record is deleted
    ///
    /// The dependent records remain but their reference to the parent is cleared.
    /// The foreign key field must be optional for this to work.
    case nullify

    /// Prevent deletion of the parent record if dependent records exist
    ///
    /// Attempts to delete the parent will fail with an error if any dependent
    /// records still reference it. This ensures referential integrity.
    case restrict
}
