import Testing
import Foundation
 import FDBRecordCore
@testable import FDBRecordLayer

/// Test record type for InExtractor tests
@Recordable
struct InExtractorTestUser {
    #Index<InExtractorTestUser>([\.city])
    #Index<InExtractorTestUser>([\.age])
    #Index<InExtractorTestUser>([\.name])
    #PrimaryKey<InExtractorTestUser>([\.userID])

    

    var userID: Int64
    var name: String
    var age: Int
    var city: String
}

/// Tests for InExtractor
///
/// Verifies that IN predicates are correctly extracted from query filters
/// and that deduplication works properly.
@Suite("InExtractor Tests")
struct InExtractorTests {

    // MARK: - Basic Extraction Tests

    @Test("Extract single IN predicate")
    func testExtractSingleInPredicate() throws {
        // Create filter with single IN predicate
        let filter = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka", "Kyoto"]
        )

        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        #expect(predicates.count == 1)
        #expect(predicates[0].fieldName == "city")
        #expect(predicates[0].valueCount == 3)
    }

    @Test("Extract multiple different IN predicates")
    func testExtractMultipleDifferentInPredicates() throws {
        // Create filter: city IN [...] AND age IN [...]
        let cityIn = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )
        let ageIn = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "age",
            values: [20, 30, 40]
        )
        let filter = TypedAndQueryComponent<InExtractorTestUser>(children: [cityIn, ageIn])

        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        #expect(predicates.count == 2)

        let cityPredicate = predicates.first { $0.fieldName == "city" }
        let agePredicate = predicates.first { $0.fieldName == "age" }

        #expect(cityPredicate != nil)
        #expect(agePredicate != nil)
        #expect(cityPredicate?.valueCount == 2)
        #expect(agePredicate?.valueCount == 3)
    }

    // MARK: - Deduplication Tests

    @Test("Deduplicate identical IN predicates")
    func testDeduplicateIdenticalInPredicates() throws {
        // Create filter: city IN ["Tokyo", "Osaka"] AND city IN ["Tokyo", "Osaka"]
        let cityIn1 = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )
        let cityIn2 = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )
        let filter = TypedAndQueryComponent<InExtractorTestUser>(children: [cityIn1, cityIn2])

        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        // Should be deduplicated to 1
        #expect(predicates.count == 1)
        #expect(predicates[0].fieldName == "city")
        #expect(predicates[0].valueCount == 2)
    }

    @Test("Deduplicate IN predicates with different value order")
    func testDeduplicateInPredicatesWithDifferentValueOrder() throws {
        // Create filter: city IN ["Tokyo", "Osaka"] AND city IN ["Osaka", "Tokyo"]
        let cityIn1 = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )
        let cityIn2 = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Osaka", "Tokyo"]  // Different order, same values
        )
        let filter = TypedAndQueryComponent<InExtractorTestUser>(children: [cityIn1, cityIn2])

        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        // Should be deduplicated to 1 (order-independent comparison)
        #expect(predicates.count == 1)
        #expect(predicates[0].fieldName == "city")
        #expect(predicates[0].valueCount == 2)
    }

    @Test("Keep distinct IN predicates on same field with different values")
    func testKeepDistinctInPredicatesOnSameField() throws {
        // Create filter: age IN [1, 2] AND age IN [3, 4]
        let ageIn1 = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "age",
            values: [1, 2]
        )
        let ageIn2 = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "age",
            values: [3, 4]  // Different values
        )
        let filter = TypedAndQueryComponent<InExtractorTestUser>(children: [ageIn1, ageIn2])

        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        // Should keep both (different value sets)
        #expect(predicates.count == 2)

        let agePredicates = predicates.filter { $0.fieldName == "age" }
        #expect(agePredicates.count == 2)
    }

    // MARK: - InPredicate Equality Tests

    @Test("InPredicate equality with same field and values")
    func testInPredicateEqualityWithSameFieldAndValues() {
        let pred1 = InPredicate(fieldName: "city", values: ["Tokyo", "Osaka"])
        let pred2 = InPredicate(fieldName: "city", values: ["Tokyo", "Osaka"])

        #expect(pred1 == pred2)
        #expect(pred1.hashValue == pred2.hashValue)
    }

    @Test("InPredicate equality with different value order")
    func testInPredicateEqualityWithDifferentValueOrder() {
        let pred1 = InPredicate(fieldName: "city", values: ["Tokyo", "Osaka"])
        let pred2 = InPredicate(fieldName: "city", values: ["Osaka", "Tokyo"])

        #expect(pred1 == pred2)
        #expect(pred1.hashValue == pred2.hashValue)
    }

    @Test("InPredicate inequality with different fields")
    func testInPredicateInequalityWithDifferentFields() {
        let pred1 = InPredicate(fieldName: "city", values: ["Tokyo"])
        let pred2 = InPredicate(fieldName: "name", values: ["Tokyo"])

        #expect(pred1 != pred2)
    }

    @Test("InPredicate inequality with different values")
    func testInPredicateInequalityWithDifferentValues() {
        let pred1 = InPredicate(fieldName: "city", values: ["Tokyo", "Osaka"])
        let pred2 = InPredicate(fieldName: "city", values: ["Tokyo", "Kyoto"])

        #expect(pred1 != pred2)
    }

    // MARK: - Matches Method Tests

    @Test("InPredicate matches TypedInQueryComponent with same values")
    func testInPredicateMatchesComponentWithSameValues() {
        let predicate = InPredicate(fieldName: "city", values: ["Tokyo", "Osaka"])
        let component = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )

        #expect(predicate.matches(component))
    }

    @Test("InPredicate matches TypedInQueryComponent with different value order")
    func testInPredicateMatchesComponentWithDifferentValueOrder() {
        let predicate = InPredicate(fieldName: "city", values: ["Tokyo", "Osaka"])
        let component = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Osaka", "Tokyo"]
        )

        #expect(predicate.matches(component))
    }

    @Test("InPredicate does not match TypedInQueryComponent with different values")
    func testInPredicateDoesNotMatchComponentWithDifferentValues() {
        let predicate = InPredicate(fieldName: "city", values: ["Tokyo", "Osaka"])
        let component = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Kyoto"]
        )

        #expect(!predicate.matches(component))
    }

    @Test("InPredicate does not match TypedInQueryComponent with different field")
    func testInPredicateDoesNotMatchComponentWithDifferentField() {
        let predicate = InPredicate(fieldName: "city", values: ["Tokyo"])
        let component = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "name",
            values: ["Tokyo"]
        )

        #expect(!predicate.matches(component))
    }

    // MARK: - Nested Filter Tests

    @Test("Extract IN from nested AND")
    func testExtractInFromNestedAnd() throws {
        // Create filter: (city IN [...] AND age > 18) AND (name IN [...])
        let cityIn = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )
        let ageFilter = TypedFieldQueryComponent<InExtractorTestUser>(
            fieldName: "age",
            comparison: .greaterThan,
            value: 18
        )
        let nameIn = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "name",
            values: ["Alice", "Bob"]
        )

        let innerAnd = TypedAndQueryComponent<InExtractorTestUser>(children: [cityIn, ageFilter])
        let outerAnd = TypedAndQueryComponent<InExtractorTestUser>(children: [innerAnd, nameIn])

        var extractor = InExtractor()
        try extractor.visit(outerAnd)

        let predicates = extractor.extractedInPredicates()
        #expect(predicates.count == 2)

        let cityPredicate = predicates.first { $0.fieldName == "city" }
        let namePredicate = predicates.first { $0.fieldName == "name" }

        #expect(cityPredicate != nil)
        #expect(namePredicate != nil)
    }

    @Test("Extract IN from OR")
    func testExtractInFromOr() throws {
        // Create filter: city IN [...] OR age IN [...]
        let cityIn = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo"]
        )
        let ageIn = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "age",
            values: [20, 30]
        )
        let filter = TypedOrQueryComponent<InExtractorTestUser>(children: [cityIn, ageIn])

        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        #expect(predicates.count == 2)
    }

    @Test("Extract IN from NOT")
    func testExtractInFromNot() throws {
        // Create filter: NOT (city IN [...])
        let cityIn = TypedInQueryComponent<InExtractorTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )
        let filter = TypedNotQueryComponent<InExtractorTestUser>(child: cityIn)

        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        #expect(predicates.count == 1)
        #expect(predicates[0].fieldName == "city")
    }
}
