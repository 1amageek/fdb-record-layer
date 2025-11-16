import Testing
import Foundation
@testable import FDBRecordLayer

@Suite("RangeWindowCalculator Tests")
struct RangeWindowCalculatorTests {

    // MARK: - Range<Date> Tests

    @Test("Calculate intersection window for two Range<Date>")
    func testRangeIntersectionTwoRanges() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)
        let date4 = Date(timeIntervalSince1970: 4000)

        let range1 = date1..<date4  // [1000, 4000)
        let range2 = date2..<date3  // [2000, 3000)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window != nil)
        #expect(window?.lowerBound == date2)  // max(1000, 2000) = 2000
        #expect(window?.upperBound == date3)  // min(4000, 3000) = 3000
    }

    @Test("Calculate intersection window for three Range<Date>")
    func testRangeIntersectionThreeRanges() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)
        let date4 = Date(timeIntervalSince1970: 4000)
        let date5 = Date(timeIntervalSince1970: 5000)

        let range1 = date1..<date5  // [1000, 5000)
        let range2 = date2..<date4  // [2000, 4000)
        let range3 = date1..<date3  // [1000, 3000)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2, range3])

        #expect(window != nil)
        #expect(window?.lowerBound == date2)  // max(1000, 2000, 1000) = 2000
        #expect(window?.upperBound == date3)  // min(5000, 4000, 3000) = 3000
    }

    @Test("No intersection returns nil")
    func testNoIntersection() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)
        let date4 = Date(timeIntervalSince1970: 4000)

        let range1 = date1..<date2  // [1000, 2000)
        let range2 = date3..<date4  // [3000, 4000)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window == nil)  // No overlap
    }

    @Test("Adjacent ranges (no overlap) returns nil")
    func testAdjacentRanges() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)

        let range1 = date1..<date2  // [1000, 2000)
        let range2 = date2..<date3  // [2000, 3000)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window == nil)  // Adjacent but no overlap (2000 is exclusive upper bound)
    }

    @Test("Empty array returns nil")
    func testEmptyArray() throws {
        let window = RangeWindowCalculator.calculateIntersectionWindow([] as [Range<Date>])

        #expect(window == nil)
    }

    @Test("Single range returns itself")
    func testSingleRange() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let range = date1..<date2

        let window = RangeWindowCalculator.calculateIntersectionWindow([range])

        #expect(window?.lowerBound == date1)
        #expect(window?.upperBound == date2)
    }

    @Test("Identical ranges return the same range")
    func testIdenticalRanges() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let range = date1..<date2

        let window = RangeWindowCalculator.calculateIntersectionWindow([range, range, range])

        #expect(window?.lowerBound == date1)
        #expect(window?.upperBound == date2)
    }

    // MARK: - PartialRangeFrom<Date> Tests

    @Test("PartialRangeFrom intersection")
    func testPartialRangeFromIntersection() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)

        let range1 = date1...  // [1000, ∞)
        let range2 = date2...  // [2000, ∞)
        let range3 = date3...  // [3000, ∞)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2, range3])

        #expect(window != nil)
        #expect(window?.lowerBound == date3)  // max(1000, 2000, 3000) = 3000
    }

    @Test("PartialRangeFrom single range returns itself")
    func testPartialRangeFromSingle() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let range = date1...

        let window = RangeWindowCalculator.calculateIntersectionWindow([range])

        #expect(window?.lowerBound == date1)
    }

    @Test("PartialRangeFrom empty array returns nil")
    func testPartialRangeFromEmpty() throws {
        let window = RangeWindowCalculator.calculateIntersectionWindow([] as [PartialRangeFrom<Date>])

        #expect(window == nil)
    }

    // MARK: - PartialRangeThrough<Date> Tests

    @Test("PartialRangeThrough intersection")
    func testPartialRangeThroughIntersection() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)

        let range1 = ...date3  // (-∞, 3000]
        let range2 = ...date2  // (-∞, 2000]
        let range3 = ...date1  // (-∞, 1000]

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2, range3])

        #expect(window != nil)
        #expect(window?.upperBound == date1)  // min(3000, 2000, 1000) = 1000
    }

    @Test("PartialRangeThrough single range returns itself")
    func testPartialRangeThroughSingle() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let range = ...date1

        let window = RangeWindowCalculator.calculateIntersectionWindow([range])

        #expect(window?.upperBound == date1)
    }

    @Test("PartialRangeThrough empty array returns nil")
    func testPartialRangeThroughEmpty() throws {
        let window = RangeWindowCalculator.calculateIntersectionWindow([] as [PartialRangeThrough<Date>])

        #expect(window == nil)
    }

    // MARK: - PartialRangeUpTo<Date> Tests

    @Test("PartialRangeUpTo intersection")
    func testPartialRangeUpToIntersection() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)

        let range1 = ..<date3  // (-∞, 3000)
        let range2 = ..<date2  // (-∞, 2000)
        let range3 = ..<date1  // (-∞, 1000)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2, range3])

        #expect(window != nil)
        #expect(window?.upperBound == date1)  // min(3000, 2000, 1000) = 1000
    }

    @Test("PartialRangeUpTo single range returns itself")
    func testPartialRangeUpToSingle() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let range = ..<date1

        let window = RangeWindowCalculator.calculateIntersectionWindow([range])

        #expect(window?.upperBound == date1)
    }

    @Test("PartialRangeUpTo empty array returns nil")
    func testPartialRangeUpToEmpty() throws {
        let window = RangeWindowCalculator.calculateIntersectionWindow([] as [PartialRangeUpTo<Date>])

        #expect(window == nil)
    }

    // MARK: - Mixed Range Types (Internal Helper)

    @Test("Mixed intersection window - both finite")
    func testMixedIntersectionBothFinite() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)
        let date4 = Date(timeIntervalSince1970: 4000)

        // Range [1000, 4000) and Range [2000, 3000)
        let lowerBounds: [Date?] = [date1, date2]
        let upperBounds: [Date?] = [date4, date3]

        let result = RangeWindowCalculator.calculateMixedIntersectionWindow(
            lowerBounds: lowerBounds,
            upperBounds: upperBounds
        )

        #expect(result != nil)
        #expect(result?.lowerBound == date2)  // max(1000, 2000) = 2000
        #expect(result?.upperBound == date3)  // min(4000, 3000) = 3000
    }

    @Test("Mixed intersection window - only lowerBound finite")
    func testMixedIntersectionOnlyLowerFinite() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        // PartialRangeFrom [1000, ∞) and [2000, ∞)
        let lowerBounds: [Date?] = [date1, date2]
        let upperBounds: [Date?] = [nil, nil]

        let result = RangeWindowCalculator.calculateMixedIntersectionWindow(
            lowerBounds: lowerBounds,
            upperBounds: upperBounds
        )

        #expect(result != nil)
        #expect(result?.lowerBound == date2)  // max(1000, 2000) = 2000
        #expect(result?.upperBound == nil)    // +∞
    }

    @Test("Mixed intersection window - only upperBound finite")
    func testMixedIntersectionOnlyUpperFinite() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        // PartialRangeThrough ...1000 and ...2000
        let lowerBounds: [Date?] = [nil, nil]
        let upperBounds: [Date?] = [date1, date2]

        let result = RangeWindowCalculator.calculateMixedIntersectionWindow(
            lowerBounds: lowerBounds,
            upperBounds: upperBounds
        )

        #expect(result != nil)
        #expect(result?.lowerBound == nil)    // -∞
        #expect(result?.upperBound == date1)  // min(1000, 2000) = 1000
    }

    @Test("Mixed intersection window - both infinite")
    func testMixedIntersectionBothInfinite() throws {
        // All ranges are infinite
        let lowerBounds: [Date?] = [nil, nil]
        let upperBounds: [Date?] = [nil, nil]

        let result = RangeWindowCalculator.calculateMixedIntersectionWindow(
            lowerBounds: lowerBounds,
            upperBounds: upperBounds
        )

        #expect(result != nil)
        #expect(result?.lowerBound == nil)  // -∞
        #expect(result?.upperBound == nil)  // +∞
    }

    @Test("Mixed intersection window - no intersection")
    func testMixedIntersectionNoOverlap() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)

        // Range [2000, 3000) and Range [1000, 1000) (invalid, but maxLower >= minUpper)
        let lowerBounds: [Date?] = [date2, date1]
        let upperBounds: [Date?] = [date3, date1]

        let result = RangeWindowCalculator.calculateMixedIntersectionWindow(
            lowerBounds: lowerBounds,
            upperBounds: upperBounds
        )

        #expect(result == nil)  // No intersection when maxLower >= minUpper
    }

    // MARK: - Real-world Scenario Tests

    @Test("Real-world: Event overlapping multiple time periods")
    func testEventOverlappingMultiplePeriods() throws {
        // Scenario: Find events overlapping with both June and July 2024
        let june1 = Date(timeIntervalSince1970: 1717200000)  // ~2024-06-01
        let june30 = Date(timeIntervalSince1970: 1719705600) // ~2024-06-30
        let july1 = Date(timeIntervalSince1970: 1719792000)  // ~2024-07-01
        let july31 = Date(timeIntervalSince1970: 1722384000) // ~2024-07-31

        let juneRange = june1..<june30
        let julyRange = july1..<july31

        let window = RangeWindowCalculator.calculateIntersectionWindow([juneRange, julyRange])

        // June and July don't overlap (June ends at 30th, July starts at 1st)
        #expect(window == nil)
    }

    @Test("Real-world: Event overlapping with Q2 and H1 2024")
    func testEventOverlappingQuarterAndHalf() throws {
        // Q2 2024: April 1 - June 30
        let q2Start = Date(timeIntervalSince1970: 1711929600)  // ~2024-04-01
        let q2End = Date(timeIntervalSince1970: 1719705600)    // ~2024-06-30

        // H1 2024: January 1 - June 30
        let h1Start = Date(timeIntervalSince1970: 1704067200)  // ~2024-01-01
        let h1End = Date(timeIntervalSince1970: 1719705600)    // ~2024-06-30

        let q2Range = q2Start..<q2End
        let h1Range = h1Start..<h1End

        let window = RangeWindowCalculator.calculateIntersectionWindow([q2Range, h1Range])

        // Intersection is Q2 (April 1 - June 30)
        #expect(window != nil)
        #expect(window?.lowerBound == q2Start)  // max(Apr 1, Jan 1) = Apr 1
        #expect(window?.upperBound == q2End)    // min(Jun 30, Jun 30) = Jun 30
    }
}
