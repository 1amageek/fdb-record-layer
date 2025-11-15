#!/usr/bin/env swift
import Foundation

// Minimal reproduction
struct TestRecord: Codable {
    var id: Int64
    var tags: [String]
}

print("Testing string array encoding/decoding...")

// Test with empty array
let record1 = TestRecord(id: 1, tags: [])
print("Record 1: \(record1)")

do {
    // This will fail because we're not importing FDBRecordLayer
    // But we can test if Codable works
    let encoder = JSONEncoder()
    let data = try encoder.encode(record1)
    print("✓ Encoded: \(data.count) bytes")

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TestRecord.self, from: data)
    print("✓ Decoded: \(decoded)")
    print("✓ Tags empty: \(decoded.tags.isEmpty)")
} catch {
    print("❌ Error: \(error)")
}
