import Testing
import Foundation
import FoundationDB
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

    // MARK: - Range<UUID> Tests

    @Test("Calculate intersection window for Range<UUID>")
    func testUUIDRangeIntersection() throws {
        // UUID v7 (time-ordered UUIDs for testing)
        let uuid1 = UUID(uuidString: "01234567-89ab-7def-0123-456789abcdef")!
        let uuid2 = UUID(uuidString: "11234567-89ab-7def-0123-456789abcdef")!
        let uuid3 = UUID(uuidString: "21234567-89ab-7def-0123-456789abcdef")!
        let uuid4 = UUID(uuidString: "31234567-89ab-7def-0123-456789abcdef")!

        let range1 = uuid1..<uuid4  // [uuid1, uuid4)
        let range2 = uuid2..<uuid3  // [uuid2, uuid3)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window != nil)
        #expect(window?.lowerBound == uuid2)  // max(uuid1, uuid2) = uuid2
        #expect(window?.upperBound == uuid3)  // min(uuid4, uuid3) = uuid3
    }

    @Test("UUID range no intersection returns nil")
    func testUUIDRangeNoIntersection() throws {
        let uuid1 = UUID(uuidString: "01234567-89ab-7def-0123-456789abcdef")!
        let uuid2 = UUID(uuidString: "11234567-89ab-7def-0123-456789abcdef")!
        let uuid3 = UUID(uuidString: "21234567-89ab-7def-0123-456789abcdef")!
        let uuid4 = UUID(uuidString: "31234567-89ab-7def-0123-456789abcdef")!

        let range1 = uuid1..<uuid2  // [uuid1, uuid2)
        let range2 = uuid3..<uuid4  // [uuid3, uuid4)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window == nil)  // No overlap
    }

    @Test("UUID single range returns itself")
    func testUUIDSingleRange() throws {
        let uuid1 = UUID(uuidString: "01234567-89ab-7def-0123-456789abcdef")!
        let uuid2 = UUID(uuidString: "11234567-89ab-7def-0123-456789abcdef")!
        let range = uuid1..<uuid2

        let window = RangeWindowCalculator.calculateIntersectionWindow([range])

        #expect(window?.lowerBound == uuid1)
        #expect(window?.upperBound == uuid2)
    }

    // MARK: - Range<Versionstamp> Tests

    // Helper function to create a versionstamp from an integer for testing
    private func makeVersionstamp(_ value: UInt64, userVersion: UInt16 = 0) -> Versionstamp {
        var bytes = [UInt8](repeating: 0, count: 10)
        withUnsafeBytes(of: value.bigEndian) { buffer in
            // Copy the 8 bytes to the end of the 10-byte array (pad with 2 zeros at start)
            for i in 0..<8 {
                bytes[i + 2] = buffer[i]
            }
        }
        return Versionstamp(transactionVersion: bytes, userVersion: userVersion)
    }

    @Test("Calculate intersection window for Range<Versionstamp>")
    func testVersionstampRangeIntersection() throws {
        // Create versionstamps with different transaction versions
        let vs1 = makeVersionstamp(1000, userVersion: 0)
        let vs2 = makeVersionstamp(2000, userVersion: 0)
        let vs3 = makeVersionstamp(3000, userVersion: 0)
        let vs4 = makeVersionstamp(4000, userVersion: 0)

        let range1 = vs1..<vs4  // [1000, 4000)
        let range2 = vs2..<vs3  // [2000, 3000)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window != nil)
        #expect(window?.lowerBound == vs2)  // max(vs1, vs2) = vs2
        #expect(window?.upperBound == vs3)  // min(vs4, vs3) = vs3
    }

    @Test("Versionstamp range no intersection returns nil")
    func testVersionstampRangeNoIntersection() throws {
        let vs1 = makeVersionstamp(1000, userVersion: 0)
        let vs2 = makeVersionstamp(2000, userVersion: 0)
        let vs3 = makeVersionstamp(3000, userVersion: 0)
        let vs4 = makeVersionstamp(4000, userVersion: 0)

        let range1 = vs1..<vs2  // [1000, 2000)
        let range2 = vs3..<vs4  // [3000, 4000)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window == nil)  // No overlap
    }

    @Test("Versionstamp single range returns itself")
    func testVersionstampSingleRange() throws {
        let vs1 = makeVersionstamp(1000, userVersion: 0)
        let vs2 = makeVersionstamp(2000, userVersion: 0)
        let range = vs1..<vs2

        let window = RangeWindowCalculator.calculateIntersectionWindow([range])

        #expect(window?.lowerBound == vs1)
        #expect(window?.upperBound == vs2)
    }

    @Test("Versionstamp with user version ordering")
    func testVersionstampUserVersionOrdering() throws {
        // Same transaction version, different user versions
        let vs1 = makeVersionstamp(1000, userVersion: 0)
        let vs2 = makeVersionstamp(1000, userVersion: 100)
        let vs3 = makeVersionstamp(1000, userVersion: 200)
        let vs4 = makeVersionstamp(1000, userVersion: 300)

        let range1 = vs1..<vs4  // [userVersion 0, 300)
        let range2 = vs2..<vs3  // [userVersion 100, 200)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window != nil)
        #expect(window?.lowerBound == vs2)  // max(0, 100) = 100
        #expect(window?.upperBound == vs3)  // min(300, 200) = 200
    }
}
