#!/usr/bin/env swift
import Foundation

// Add the module path
#if canImport(FDBRecordLayer)
import FDBRecordLayer
#endif

// Simple test struct
struct SimpleTest: Codable {
    var id: Int64
    var name: String
}

print("Testing ProtobufEncoder...")

let record = SimpleTest(id: 123, name: "Test")
print("Created record: \(record)")

do {
    // Test with ProtobufEncoder
    let encoder = ProtobufEncoder()
    let data = try encoder.encode(record)
    print("✓ Encoded successfully: \(data.count) bytes")
    print("  Data: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")

    // Test with ProtobufDecoder
    let decoder = ProtobufDecoder()
    let decoded = try decoder.decode(SimpleTest.self, from: data)
    print("✓ Decoded successfully: id=\(decoded.id), name=\(decoded.name)")

    // Verify
    if decoded.id == record.id && decoded.name == record.name {
        print("✅ Test PASSED!")
    } else {
        print("❌ Test FAILED - values don't match")
    }
} catch {
    print("❌ Test FAILED with error: \(error)")
    if let encodingError = error as? EncodingError {
        print("   Encoding error: \(encodingError)")
    }
    if let decodingError = error as? DecodingError {
        print("   Decoding error: \(decodingError)")
    }
}
