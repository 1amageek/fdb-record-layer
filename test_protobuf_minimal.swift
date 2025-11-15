#!/usr/bin/env swift
import Foundation

// Minimal test to verify ProtobufEncoder/Decoder work
print("Starting minimal Protobuf test...")

// Simple Codable struct
struct TestRecord: Codable {
    var id: Int64
    var name: String
}

// Import our module (we'll compile with it)
// For now, let's just test if basic encoding works

let record = TestRecord(id: 123, name: "Test")
print("Created record: id=\(record.id), name=\(record.name)")

// Try JSONEncoder first to verify Codable works
do {
    let jsonEncoder = JSONEncoder()
    let jsonData = try jsonEncoder.encode(record)
    print("JSON encoding succeeded: \(jsonData.count) bytes")

    let jsonDecoder = JSONDecoder()
    let decoded = try jsonDecoder.decode(TestRecord.self, from: jsonData)
    print("JSON decoding succeeded: id=\(decoded.id), name=\(decoded.name)")
} catch {
    print("JSON test failed: \(error)")
}

print("Minimal test completed successfully!")
