import Testing
import Foundation
@testable import FDBRecordLayer

@Recordable
struct MinimalUser {
    @PrimaryKey var id: Int64
    var email: String
}

@Suite("Minimal Index Test")
struct MinimalIndexTest {
    @Test("Check basic record")
    func testBasicRecord() {
        #expect(MinimalUser.recordName == "MinimalUser")
        #expect(MinimalUser.primaryKeyFields.contains("id"))
    }
}
