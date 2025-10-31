import Foundation
import Testing
import FoundationDB
@testable import FDBRecordLayer

/// Tests for Permuted Index functionality
@Suite("Permuted Index Tests")
struct PermutedIndexTests {

    // MARK: - Permutation Tests

    @Test("Permutation initialization with valid indices")
    func testPermutationInit() throws {
        let perm = try Permutation(indices: [1, 0, 2])

        #expect(perm.indices == [1, 0, 2])
    }

    @Test("Permutation identity")
    func testIdentityPermutation() {
        let perm = Permutation.identity(size: 3)

        #expect(perm.isIdentity)
        #expect(perm.indices == [0, 1, 2])
    }

    @Test("Permutation validation fails for invalid indices")
    func testInvalidPermutation() {
        #expect(throws: RecordLayerError.self) {
            _ = try Permutation(indices: [0, 1, 1])  // Duplicate
        }

        #expect(throws: RecordLayerError.self) {
            _ = try Permutation(indices: [0, 2])  // Missing 1
        }

        #expect(throws: RecordLayerError.self) {
            _ = try Permutation(indices: [])  // Empty
        }
    }

    @Test("Permutation apply")
    func testPermutationApply() throws {
        let perm = try Permutation(indices: [2, 0, 1])
        let input = ["A", "B", "C"]

        let result = try perm.apply(input)

        #expect(result == ["C", "A", "B"])
    }

    @Test("Permutation inverse")
    func testPermutationInverse() throws {
        let perm = try Permutation(indices: [2, 0, 1])
        let inverse = perm.inverse

        let input = ["A", "B", "C"]
        let permuted = try perm.apply(input)
        let restored = try inverse.apply(permuted)

        #expect(restored == input)
    }

    @Test("Permutation equality")
    func testPermutationEquality() throws {
        let perm1 = try Permutation(indices: [1, 0, 2])
        let perm2 = try Permutation(indices: [1, 0, 2])
        let perm3 = try Permutation(indices: [0, 1, 2])

        #expect(perm1 == perm2)
        #expect(perm1 != perm3)
    }

    @Test("Permutation hashable")
    func testPermutationHashable() throws {
        let perm1 = try Permutation(indices: [1, 0, 2])
        let perm2 = try Permutation(indices: [1, 0, 2])

        var set: Set<Permutation> = []
        set.insert(perm1)
        set.insert(perm2)

        #expect(set.count == 1)
    }

    @Test("Permutation description")
    func testPermutationDescription() throws {
        let perm = try Permutation(indices: [2, 0, 1])

        #expect(perm.description == "[2, 0, 1]")
    }

    // MARK: - IndexOptions Extension Tests

    @Test("IndexOptions permuted factory method")
    func testIndexOptionsPermuted() throws {
        let perm = try Permutation(indices: [1, 0, 2])
        let options = IndexOptions.permuted(
            baseIndexName: "base_index",
            permutation: perm
        )

        #expect(options.baseIndexName == "base_index")
        #expect(options.permutation == perm)
    }

    @Test("IndexOptions permutation property")
    func testIndexOptionsPermutationProperty() throws {
        var options = IndexOptions()
        let perm = try Permutation(indices: [2, 1, 0])

        options.permutationIndices = perm.indices

        #expect(options.permutation == perm)
    }

    // MARK: - PermutedIndexMaintainer Tests

    @Test("PermutedIndexMaintainer initialization")
    func testPermutedIndexMaintainerInit() throws {
        let perm = try Permutation(indices: [1, 0])
        let index = Index(
            name: "permuted_test",
            type: IndexType.permuted,
            rootExpression: EmptyKeyExpression(),
            options: IndexOptions.permuted(
                baseIndexName: "base_index",
                permutation: perm
            )
        )

        let subspace = Subspace(prefix: Tuple("permuted").encode())
        let recordSubspace = Subspace(prefix: Tuple("records").encode())

        let maintainer = try PermutedIndexMaintainer(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )

        #expect(maintainer.index.name == "permuted_test")
    }

    @Test("PermutedIndexMaintainer requires baseIndexName")
    func testPermutedIndexMaintainerRequiresBase() {
        let index = Index(
            name: "permuted_test",
            type: IndexType.permuted,
            rootExpression: EmptyKeyExpression(),
            options: IndexOptions()  // Missing baseIndexName
        )

        let subspace = Subspace(prefix: Tuple("permuted").encode())
        let recordSubspace = Subspace(prefix: Tuple("records").encode())

        #expect(throws: RecordLayerError.self) {
            _ = try PermutedIndexMaintainer(
                index: index,
                subspace: subspace,
                recordSubspace: recordSubspace
            )
        }
    }

    @Test("PermutedIndexMaintainer requires permutation")
    func testPermutedIndexMaintainerRequiresPermutation() {
        var options = IndexOptions()
        options.baseIndexName = "base_index"
        // Missing permutation

        let index = Index(
            name: "permuted_test",
            type: IndexType.permuted,
            rootExpression: EmptyKeyExpression(),
            options: options
        )

        let subspace = Subspace(prefix: Tuple("permuted").encode())
        let recordSubspace = Subspace(prefix: Tuple("records").encode())

        #expect(throws: RecordLayerError.self) {
            _ = try PermutedIndexMaintainer(
                index: index,
                subspace: subspace,
                recordSubspace: recordSubspace
            )
        }
    }

    // MARK: - Validation Tests

    @Test("validatePermutation with matching field count")
    func testValidatePermutationSuccess() throws {
        let perm = try Permutation(indices: [2, 0, 1])

        // Should not throw
        try PermutedIndexMaintainer.validatePermutation(perm, fieldCount: 3)
    }

    @Test("validatePermutation with mismatched field count")
    func testValidatePermutationMismatch() throws {
        let perm = try Permutation(indices: [1, 0])

        #expect(throws: RecordLayerError.self) {
            try PermutedIndexMaintainer.validatePermutation(perm, fieldCount: 3)
        }
    }
}
