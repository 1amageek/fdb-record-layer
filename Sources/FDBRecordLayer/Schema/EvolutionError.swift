import Foundation

public enum EvolutionError: Error, Sendable, CustomStringConvertible {
    case recordTypeDeleted(recordType: String)
    case fieldDeleted(recordType: String, fieldName: String)
    case fieldTypeChanged(recordType: String, fieldName: String, old: String, new: String)
    case requiredFieldAdded(recordType: String, fieldName: String)
    case enumValueDeleted(typeName: String, deletedValues: [String])
    case indexFormatChanged(indexName: String)
    case indexDeletedWithoutFormerIndex(indexName: String)

    public var description: String {
        switch self {
        case .recordTypeDeleted(let recordType):
            return "Record type '\(recordType)' was deleted (forbidden)"
        case .fieldDeleted(let recordType, let fieldName):
            return "Field '\(fieldName)' in record type '\(recordType)' was deleted (forbidden)"
        case .fieldTypeChanged(let recordType, let fieldName, let old, let new):
            return "Field '\(fieldName)' in record type '\(recordType)' changed type from '\(old)' to '\(new)' (forbidden)"
        case .requiredFieldAdded(let recordType, let fieldName):
            return "Required field '\(fieldName)' added to '\(recordType)' (forbidden)"
        case .enumValueDeleted(let typeName, let deletedValues):
            return "Enum '\(typeName)' had values deleted: [\(deletedValues.joined(separator: ", "))]"
        case .indexFormatChanged(let indexName):
            return "Index '\(indexName)' format was changed (forbidden)"
        case .indexDeletedWithoutFormerIndex(let indexName):
            return "Index '\(indexName)' deleted without FormerIndex (forbidden)"
        }
    }
}
