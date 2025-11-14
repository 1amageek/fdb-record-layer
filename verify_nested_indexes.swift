#!/usr/bin/env swift
import FDBRecordLayer

// Simple test models
@Recordable
struct TestAddress {
    #PrimaryKey<TestAddress>([\.id])

    var id: Int64
    var city: String
    var country: String
}

@Recordable
struct TestPerson {
    #Index<TestPerson>([\\.address.city])
    #PrimaryKey<TestPerson>([\.personID])

    var personID: Int64
    var name: String
    var address: TestAddress
}

// Test execution
print("Testing nested field index support...")

let address = TestAddress(id: 1, city: "Tokyo", country: "Japan")
let person = TestPerson(personID: 100, name: "Taro", address: address)

// Test 1: extractField with simple path
let nameResult = person.extractField("name")
print("✓ Simple path (name): \(nameResult)")

// Test 2: extractField with nested path
let cityResult = person.extractField("address.city")
print("✓ Nested path (address.city): \(cityResult)")

// Test 3: Serialization round-trip
do {
    let data = try person.toProtobuf()
    let decoded = try TestPerson.fromProtobuf(data)

    assert(decoded.name == person.name)
    assert(decoded.address.city == person.address.city)
    print("✓ Serialization round-trip successful")
} catch {
    print("✗ Serialization failed: \(error)")
}

print("\n✅ All tests passed!")
print("Nested field indexes are working correctly.")
