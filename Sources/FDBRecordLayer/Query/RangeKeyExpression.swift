import Foundation
import FoundationDB

/// Range型フィールドから境界値を抽出するKeyExpression
///
/// RangeKeyExpressionは、Range型フィールド（Range<T>, ClosedRange<T>, Partial Rangesなど）から
/// lowerBoundまたはupperBoundを個別に抽出するためのKeyExpressionです。
///
/// **用途**:
/// - Range型フィールドに対するインデックス構築
/// - Range境界値での効率的な範囲クエリ
/// - overlaps, contains などの範囲クエリ演算子のサポート
///
/// **インデックス構造**:
/// Range型フィールドには2つのインデックスが自動生成されます：
/// - `{recordType}_{fieldName}_start_index`: lowerBound用
/// - `{recordType}_{fieldName}_end_index`: upperBound用
///
/// **使用例**:
/// ```swift
/// @Recordable
/// struct Event {
///     #PrimaryKey<Event>([\.id])
///     #Index<Event>([\.period])  // Range<Date>を自動検出
///
///     var id: Int64
///     var period: Range<Date>
/// }
///
/// // 内部的に2つのRangeKeyExpressionが生成される:
/// // - RangeKeyExpression(fieldName: "period", component: .lowerBound)
/// // - RangeKeyExpression(fieldName: "period", component: .upperBound)
/// ```
///
/// **クエリ例**:
/// ```swift
/// // 2024-01-01 18:00-20:00 と重複するイベントを検索
/// let searchRange = date1..<date2
/// let events = try await store.query(Event.self)
///     .overlaps(\.period, with: searchRange)
///     .execute()
///
/// // 内部的には以下の条件に変換される:
/// // - period.lowerBound < 2024-01-01 20:00
/// // - period.upperBound > 2024-01-01 18:00
/// ```
public struct RangeKeyExpression: KeyExpression {
    /// Range型フィールド名
    public let fieldName: String

    /// 抽出する境界成分（lowerBound/upperBound）
    public let component: RangeComponent

    /// 境界タイプ（半開区間 or 閉区間）
    ///
    /// - halfOpen: Range<T>, PartialRangeUpTo<T> → [a, b)
    /// - closed: ClosedRange<T>, PartialRangeFrom<T>, PartialRangeThrough<T> → [a, b]
    public let boundaryType: BoundaryType

    /// Initialize a RangeKeyExpression
    ///
    /// - Parameters:
    ///   - fieldName: The field name containing the Range type
    ///   - component: The boundary component to extract
    ///   - boundaryType: The boundary type (halfOpen or closed), defaults to halfOpen
    public init(
        fieldName: String,
        component: RangeComponent,
        boundaryType: BoundaryType = .halfOpen
    ) {
        self.fieldName = fieldName
        self.component = component
        self.boundaryType = boundaryType
    }

    // MARK: - KeyExpression Protocol

    /// Column count is always 1 (a single boundary value)
    public var columnCount: Int {
        return 1
    }

    /// Accept a visitor to evaluate this expression
    ///
    /// This method implements the Visitor pattern, delegating the actual evaluation
    /// to the visitor's `visitRangeBoundary()` method.
    ///
    /// - Parameter visitor: The visitor to accept
    /// - Returns: The result of the visitor's evaluation
    /// - Throws: If the visitor encounters an error
    public func accept<V: KeyExpressionVisitor>(visitor: V) throws -> V.Result {
        return try visitor.visitRangeBoundary(fieldName, component)
    }
}

// MARK: - CustomStringConvertible

extension RangeKeyExpression: CustomStringConvertible {
    public var description: String {
        return "RangeKeyExpression(\(fieldName).\(component))"
    }
}

// MARK: - Equatable

extension RangeKeyExpression: Equatable {
    public static func == (lhs: RangeKeyExpression, rhs: RangeKeyExpression) -> Bool {
        return lhs.fieldName == rhs.fieldName &&
               lhs.component == rhs.component &&
               lhs.boundaryType == rhs.boundaryType
    }
}
