import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Regression tests for Date encoding in TupleHelpers
///
/// **Background**: Range type indexes were silently failing because:
/// 1. Date was not a TupleElement in fdb-swift-bindings
/// 2. TupleHelpers.toTuple() fell back to empty string for Date
///
/// These tests ensure Date values are correctly encoded as Double timestamps
/// and can round-trip through Tuple encoding/decoding.
@Suite("TupleHelpers Date Encoding Tests")
struct TupleHelpersDateTests {

    // MARK: - Core Regression Tests

    @Test("Date encodes as Double timestamp (not empty string)")
    func testDateEncodesAsDouble() throws {
        let date = Date(timeIntervalSince1970: 1234567890.123456)
        let tuple = TupleHelpers.toTuple(date)

        // Verify tuple is not empty
        #expect(tuple.count == 1, "Tuple should contain 1 element")

        // Verify element is Double (not empty string fallback)
        guard let element = tuple[0] else {
            #expect(Bool(false), "Tuple should have element at index 0")
            return
        }
        #expect(element is Double, "Date should be encoded as Double, not empty string")

        // Verify value matches timeIntervalSince1970
        let timestamp = element as! Double
        #expect(timestamp == date.timeIntervalSince1970, "Timestamp should match Date.timeIntervalSince1970")
    }

    @Test("Date round-trips through Tuple encoding")
    func testDateRoundTrip() throws {
        let originalDate = Date(timeIntervalSince1970: 1609459200.123456)

        // Encode to Tuple
        let tuple = TupleHelpers.toTuple(originalDate)

        // Pack to bytes
        let bytes = tuple.pack()

        // Unpack back to array
        let unpackedElements = try Tuple.unpack(from: bytes)

        // Extract Date
        #expect(unpackedElements.count > 0, "Unpacked array should have at least 1 element")
        let element = unpackedElements[0]
        let timestamp = element as! Double
        let recoveredDate = Date(timeIntervalSince1970: timestamp)

        // Verify dates match with microsecond precision
        #expect(abs(recoveredDate.timeIntervalSince1970 - originalDate.timeIntervalSince1970) < 0.000001,
                "Date should round-trip with microsecond precision")
    }

    @Test("Array of Dates encodes correctly")
    func testArrayOfDatesEncodesCorrectly() throws {
        let dates: [any TupleElement] = [
            Date(timeIntervalSince1970: 1000.0),
            Date(timeIntervalSince1970: 2000.0),
            Date(timeIntervalSince1970: 3000.0)
        ]

        let tuple = TupleHelpers.toTuple(dates)

        // Verify all dates are encoded
        #expect(tuple.count == 3, "Tuple should contain 3 elements")

        // Verify each element is Double
        for i in 0..<3 {
            guard let element = tuple[i] else {
                #expect(Bool(false), "Tuple should have element at index \(i)")
                continue
            }
            #expect(element is Double, "Element \(i) should be Double")

            let timestamp = element as! Double
            let expectedDate = dates[i] as! Date
            #expect(timestamp == expectedDate.timeIntervalSince1970,
                    "Element \(i) timestamp should match")
        }
    }

    @Test("Mixed types including Date encode correctly")
    func testMixedTypesWithDate() throws {
        let elements: [any TupleElement] = [
            "category" as String,
            Date(timeIntervalSince1970: 1609459200.0),
            Int64(123)
        ]

        let tuple = TupleHelpers.toTuple(elements)

        // Verify all elements are encoded
        #expect(tuple.count == 3, "Tuple should contain 3 elements")

        // Verify String
        guard let strElement = tuple[0] else {
            #expect(Bool(false), "Tuple should have element at index 0")
            return
        }
        let str = strElement as! String
        #expect(str == "category")

        // Verify Date (as Double)
        guard let dateElement = tuple[1] else {
            #expect(Bool(false), "Tuple should have element at index 1")
            return
        }
        let timestamp = dateElement as! Double
        #expect(timestamp == 1609459200.0)

        // Verify Int64
        guard let intElement = tuple[2] else {
            #expect(Bool(false), "Tuple should have element at index 2")
            return
        }
        let int = intElement as! Int64
        #expect(int == 123)
    }

    // MARK: - Range Index Scenario

    @Test("Range boundaries encode correctly for index keys")
    func testRangeBoundariesForIndexKeys() throws {
        // Simulate Range<Date> boundaries in index key
        let lowerBound = Date(timeIntervalSince1970: 50.0)
        let upperBound = Date(timeIntervalSince1970: 150.0)

        // Encode as index key components (typical Range index scenario)
        let indexValues: [any TupleElement] = [lowerBound]
        let primaryKey: [any TupleElement] = [Int64(1)]
        let allValues = indexValues + primaryKey

        let tuple = TupleHelpers.toTuple(allValues)

        // Verify structure: [boundary, primaryKey]
        #expect(tuple.count == 2, "Tuple should have 2 elements")

        // Verify boundary is Double
        guard let boundaryElement = tuple[0] else {
            #expect(Bool(false), "Tuple should have element at index 0")
            return
        }
        let boundary = boundaryElement as! Double
        #expect(boundary == 50.0)

        // Verify primary key
        guard let pkElement = tuple[1] else {
            #expect(Bool(false), "Tuple should have element at index 1")
            return
        }
        let pk = pkElement as! Int64
        #expect(pk == 1)

        // CRITICAL: Verify lexicographic ordering matches chronological ordering
        let lowerTuple = TupleHelpers.toTuple([lowerBound, Int64(1)])
        let upperTuple = TupleHelpers.toTuple([upperBound, Int64(1)])

        let lowerPacked = lowerTuple.pack()
        let upperPacked = upperTuple.pack()

        #expect(lowerPacked.lexicographicallyPrecedes(upperPacked),
                "Earlier Date must encode to lexicographically smaller bytes")
    }

    // MARK: - Edge Cases

    @Test("Unix epoch encodes correctly")
    func testUnixEpochEncodesCorrectly() throws {
        let epoch = Date(timeIntervalSince1970: 0.0)
        let tuple = TupleHelpers.toTuple(epoch)

        guard let element = tuple[0] else {
            #expect(Bool(false), "Tuple should have element at index 0")
            return
        }
        let timestamp = element as! Double
        #expect(timestamp == 0.0, "Unix epoch should encode as 0.0")
    }

    @Test("Negative timestamp (before 1970) encodes correctly")
    func testNegativeTimestampEncodesCorrectly() throws {
        let pastDate = Date(timeIntervalSince1970: -86400.0) // 1969-12-31
        let tuple = TupleHelpers.toTuple(pastDate)

        guard let element = tuple[0] else {
            #expect(Bool(false), "Tuple should have element at index 0")
            return
        }
        let timestamp = element as! Double
        #expect(timestamp == -86400.0, "Dates before 1970 should encode as negative timestamps")
    }

    @Test("Microsecond precision is preserved")
    func testMicrosecondPrecisionPreserved() throws {
        let date = Date(timeIntervalSince1970: 1234567890.123456)
        let tuple = TupleHelpers.toTuple(date)

        guard let element = tuple[0] else {
            #expect(Bool(false), "Tuple should have element at index 0")
            return
        }
        let timestamp = element as! Double
        #expect(abs(timestamp - 1234567890.123456) < 0.000001,
                "Microsecond precision should be preserved")
    }

    @Test("Lexicographic ordering matches chronological ordering")
    func testLexicographicOrderingMatchesChronological() throws {
        let dates = [
            Date(timeIntervalSince1970: 100.0),
            Date(timeIntervalSince1970: 200.0),
            Date(timeIntervalSince1970: 300.0),
            Date(timeIntervalSince1970: 1000.0),
            Date(timeIntervalSince1970: 10000.0)
        ]

        let tuples = dates.map { TupleHelpers.toTuple($0) }
        let packedBytes = tuples.map { $0.pack() }

        // Verify lexicographic ordering matches chronological ordering
        for i in 0..<(packedBytes.count - 1) {
            #expect(packedBytes[i].lexicographicallyPrecedes(packedBytes[i + 1]),
                    "Date[\(i)] bytes must be < Date[\(i+1)] bytes")
        }
    }
}
