import Testing
import Foundation
@testable import FDBRecordCore
@testable import FoundationDB
@testable import FDBRecordLayer

/// Minimal test case to isolate PartialRange compiler crash
@Suite("PartialRange Minimal Test")
struct PartialRangeMinimalTest {

    /// Simplest possible PartialRange model
    @Recordable
    struct MinimalPartialRange {
        #PrimaryKey<MinimalPartialRange>([\.id])
        #Index<MinimalPartialRange>([\.validFrom.lowerBound])

        var id: Int64
        var validFrom: PartialRangeFrom<Date>
    }

    /// Another struct with Range<Date> (like in RangeIndexEndToEndTests)
    @Recordable
    struct RegularRange {
        #PrimaryKey<RegularRange>([\.id])
        #Index<RegularRange>([\.period.lowerBound])
        #Index<RegularRange>([\.period.upperBound])

        var id: Int64
        var period: Range<Date>
    }

    /// Now add OpenEndEvent (same as in RangeIndexEndToEndTests)
    @Recordable
    struct OpenEndEvent {
        #PrimaryKey<OpenEndEvent>([\.id])
        #Index<OpenEndEvent>([\.validFrom.lowerBound])

        var id: Int64
        var validFrom: PartialRangeFrom<Date>
        var title: String
    }

    /// Test model with PartialRangeThrough field
    @Recordable
    struct OpenStartEvent {
        #PrimaryKey<OpenStartEvent>([\.id])
        #Index<OpenStartEvent>([\.validThrough.upperBound])

        var id: Int64
        var validThrough: PartialRangeThrough<Date>
        var title: String
    }

    /// Test model with PartialRangeUpTo field
    @Recordable
    struct OpenStartExclusiveEvent {
        #PrimaryKey<OpenStartExclusiveEvent>([\.id])
        #Index<OpenStartExclusiveEvent>([\.validUpTo.upperBound])

        var id: Int64
        var validUpTo: PartialRangeUpTo<Date>
        var title: String
    }

    @Test("Basic PartialRange struct compiles")
    func testBasicCompilation() {
        // If this test runs, the struct compiled successfully
        #expect(MinimalPartialRange.recordName == "MinimalPartialRange")
    }

    @Test("OpenEndEvent compiles")
    func testOpenEndEventCompiles() {
        #expect(OpenEndEvent.recordName == "OpenEndEvent")
    }

    @Test("OpenStartEvent compiles")
    func testOpenStartEventCompiles() {
        #expect(OpenStartEvent.recordName == "OpenStartEvent")
    }

    @Test("OpenStartExclusiveEvent compiles")
    func testOpenStartExclusiveEventCompiles() {
        #expect(OpenStartExclusiveEvent.recordName == "OpenStartExclusiveEvent")
    }
}
