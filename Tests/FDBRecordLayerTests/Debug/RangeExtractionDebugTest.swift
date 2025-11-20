import Testing
import Foundation
@testable import FDBRecordCore
@testable import FoundationDB
@testable import FDBRecordLayer

/// Debug test to verify Range boundary extraction
@Suite("Range Extraction Debug Tests")
struct RangeExtractionDebugTest {

    @Recordable
    struct TestEvent {
        #PrimaryKey<TestEvent>([\.id])
        var id: Int64
        var period: Range<Date>
        var title: String
    }

    @Test("extractRangeBoundary() works correctly")
    func testExtractRangeBoundary() throws {
        let event = TestEvent(
            id: 1,
            period: Date(timeIntervalSince1970: 100)..<Date(timeIntervalSince1970: 200),
            title: "Test"
        )

        let recordAccess = GenericRecordAccess<TestEvent>()

        // Test lowerBound extraction
        let lowerBound = try recordAccess.extractRangeBoundary(
            from: event,
            fieldName: "period",
            component: .lowerBound
        )

        print("✅ lowerBound extracted: \(lowerBound)")
        #expect(lowerBound.count == 1)

        if let date = lowerBound[0] as? Date {
            print("   Date: \(date.timeIntervalSince1970)")
            #expect(date.timeIntervalSince1970 == 100.0)
        } else {
            print("   ❌ Not a Date: \(type(of: lowerBound[0]))")
            throw RecordLayerError.internalError("lowerBound is not a Date")
        }

        // Test upperBound extraction
        let upperBound = try recordAccess.extractRangeBoundary(
            from: event,
            fieldName: "period",
            component: .upperBound
        )

        print("✅ upperBound extracted: \(upperBound)")
        #expect(upperBound.count == 1)

        if let date = upperBound[0] as? Date {
            print("   Date: \(date.timeIntervalSince1970)")
            #expect(date.timeIntervalSince1970 == 200.0)
        } else {
            print("   ❌ Not a Date: \(type(of: upperBound[0]))")
            throw RecordLayerError.internalError("upperBound is not a Date")
        }
    }

    @Test("TypedKeyExpressionQueryComponent.matches() works correctly")
    func testKeyExpressionQueryComponentMatches() throws {
        let event = TestEvent(
            id: 1,
            period: Date(timeIntervalSince1970: 100)..<Date(timeIntervalSince1970: 200),
            title: "Test"
        )

        let recordAccess = GenericRecordAccess<TestEvent>()

        // Test: period.lowerBound < 150
        let filter1 = TypedKeyExpressionQueryComponent<TestEvent>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .lowerBound,
                boundaryType: .halfOpen
            ),
            comparison: .lessThan,
            value: Date(timeIntervalSince1970: 150)
        )

        let matches1 = try filter1.matches(record: event, recordAccess: recordAccess)
        print("✅ Filter1 (lowerBound < 150): \(matches1) (expected: true, since 100 < 150)")
        #expect(matches1 == true)

        // Test: period.upperBound > 50
        let filter2 = TypedKeyExpressionQueryComponent<TestEvent>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .upperBound,
                boundaryType: .halfOpen
            ),
            comparison: .greaterThan,
            value: Date(timeIntervalSince1970: 50)
        )

        let matches2 = try filter2.matches(record: event, recordAccess: recordAccess)
        print("✅ Filter2 (upperBound > 50): \(matches2) (expected: true, since 200 > 50)")
        #expect(matches2 == true)

        // Test: period.lowerBound < 50 (should be false)
        let filter3 = TypedKeyExpressionQueryComponent<TestEvent>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .lowerBound,
                boundaryType: .halfOpen
            ),
            comparison: .lessThan,
            value: Date(timeIntervalSince1970: 50)
        )

        let matches3 = try filter3.matches(record: event, recordAccess: recordAccess)
        print("✅ Filter3 (lowerBound < 50): \(matches3) (expected: false, since 100 >= 50)")
        #expect(matches3 == false)
    }

    @Test("extractRangeBoundary() works with existential type")
    func testExtractRangeBoundaryWithExistential() throws {
        let event = TestEvent(
            id: 1,
            period: Date(timeIntervalSince1970: 100)..<Date(timeIntervalSince1970: 200),
            title: "Test"
        )

        // ❗ Use existential type (any RecordAccess) - this is what happens in real query execution
        let existential: any RecordAccess<TestEvent> = GenericRecordAccess<TestEvent>()

        // Test lowerBound extraction via existential
        let lowerBound = try existential.extractRangeBoundary(
            from: event,
            fieldName: "period",
            component: .lowerBound
        )

        print("✅ [Existential] lowerBound extracted: \(lowerBound)")
        #expect(lowerBound.count == 1)

        if let date = lowerBound[0] as? Date {
            print("   [Existential] Date: \(date.timeIntervalSince1970)")
            #expect(date.timeIntervalSince1970 == 100.0)
        } else {
            print("   ❌ [Existential] Not a Date: \(type(of: lowerBound[0]))")
            throw RecordLayerError.internalError("lowerBound is not a Date")
        }

        // Test with TypedKeyExpressionQueryComponent via existential
        let filter = TypedKeyExpressionQueryComponent<TestEvent>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .lowerBound,
                boundaryType: .halfOpen
            ),
            comparison: .lessThan,
            value: Date(timeIntervalSince1970: 150)
        )

        let matches = try filter.matches(record: event, recordAccess: existential)
        print("✅ [Existential] Filter matches: \(matches) (expected: true)")
        #expect(matches == true)
    }

    @Test("overlaps() filter logic works correctly")
    func testOverlapsFilterLogic() throws {
        let event = TestEvent(
            id: 1,
            period: Date(timeIntervalSince1970: 100)..<Date(timeIntervalSince1970: 200),
            title: "Test"
        )

        let recordAccess = GenericRecordAccess<TestEvent>()

        // Query range: [75, 125)
        let queryRange = Date(timeIntervalSince1970: 75)..<Date(timeIntervalSince1970: 125)

        // Condition 1: period.lowerBound < queryRange.upperBound
        let filter1 = TypedKeyExpressionQueryComponent<TestEvent>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .lowerBound,
                boundaryType: .halfOpen
            ),
            comparison: .lessThan,
            value: queryRange.upperBound
        )

        let matches1 = try filter1.matches(record: event, recordAccess: recordAccess)
        print("Condition 1 (lowerBound < queryUpperBound): \(matches1)")
        print("  100 < 125 = \(matches1) (expected: true)")

        // Condition 2: period.upperBound > queryRange.lowerBound
        let filter2 = TypedKeyExpressionQueryComponent<TestEvent>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .upperBound,
                boundaryType: .halfOpen
            ),
            comparison: .greaterThan,
            value: queryRange.lowerBound
        )

        let matches2 = try filter2.matches(record: event, recordAccess: recordAccess)
        print("Condition 2 (upperBound > queryLowerBound): \(matches2)")
        print("  200 > 75 = \(matches2) (expected: true)")

        // Combined with AND
        let overlaps = matches1 && matches2
        print("✅ Overlaps result: \(overlaps) (expected: true)")
        #expect(overlaps == true)
    }
}
