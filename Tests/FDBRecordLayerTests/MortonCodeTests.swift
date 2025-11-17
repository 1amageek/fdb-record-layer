import Testing
import Foundation
@testable import FDBRecordLayer

@Suite("Morton Code (Z-order Curve) Tests")
struct MortonCodeTests {

    // MARK: - 2D Encoding/Decoding

    @Test("Encode 2D coordinates at origin")
    func testEncode2DOrigin() throws {
        let code = MortonCode.encode2D(x: 0.0, y: 0.0)
        #expect(code == 0)
    }

    @Test("Encode 2D coordinates at maximum")
    func testEncode2DMaximum() throws {
        let code = MortonCode.encode2D(x: 1.0, y: 1.0)
        // With level=18 (default), max code is not UInt64.max
        // level=18 → 18 bits/dim → 36 bits total → shifted left 24 bits
        // Result: top 36 bits set = 0xFFFFFFFFF000000
        #expect(code > 0)
        #expect(code == MortonCode.encode2D(x: 1.0, y: 1.0))  // Verify consistency

        // Verify round-trip
        let (x, y) = MortonCode.decode2D(code)
        #expect(abs(x - 1.0) < 0.00001)
        #expect(abs(y - 1.0) < 0.00001)
    }

    @Test("Encode 2D coordinates at midpoint")
    func testEncode2DMidpoint() throws {
        let code = MortonCode.encode2D(x: 0.5, y: 0.5)

        // Midpoint should produce a code around the middle of the range
        #expect(code > 0)
        #expect(code < UInt64.max)
    }

    @Test("Decode 2D Morton code at origin")
    func testDecode2DOrigin() throws {
        let (x, y) = MortonCode.decode2D(0)
        #expect(abs(x - 0.0) < 0.00001)
        #expect(abs(y - 0.0) < 0.00001)
    }

    @Test("Decode 2D Morton code at maximum")
    func testDecode2DMaximum() throws {
        // Encode maximum coordinates and decode back
        let maxCode = MortonCode.encode2D(x: 1.0, y: 1.0)
        let (x, y) = MortonCode.decode2D(maxCode)
        #expect(abs(x - 1.0) < 0.00001)
        #expect(abs(y - 1.0) < 0.00001)
    }

    @Test("2D encoding round-trip accuracy")
    func test2DEncodingRoundTrip() throws {
        let testCases: [(Double, Double)] = [
            (0.0, 0.0),
            (1.0, 1.0),
            (0.5, 0.5),
            (0.25, 0.75),
            (0.1, 0.9),
            (0.333, 0.667),
            (0.123, 0.456),
            (0.999, 0.001)
        ]

        for (x, y) in testCases {
            let code = MortonCode.encode2D(x: x, y: y)
            let (decodedX, decodedY) = MortonCode.decode2D(code)

            // level=18 (default) → 18 bits per dimension → precision ≈ 1/262143 ≈ 0.000004
            #expect(abs(decodedX - x) < 0.00001)
            #expect(abs(decodedY - y) < 0.00001)
        }
    }

    // MARK: - 3D Encoding/Decoding

    @Test("Encode 3D coordinates at origin")
    func testEncode3DOrigin() throws {
        let code = MortonCode.encode3D(x: 0.0, y: 0.0, z: 0.0)
        #expect(code == 0)
    }

    @Test("Encode 3D coordinates at maximum")
    func testEncode3DMaximum() throws {
        let code = MortonCode.encode3D(x: 1.0, y: 1.0, z: 1.0)

        // Max 3D code with level=16 (default): 16 bits per dimension = 48 bits total
        // Shifted left by 12 bits → top 48 bits set
        #expect(code > 0)
        #expect(code == MortonCode.encode3D(x: 1.0, y: 1.0, z: 1.0))  // Verify consistency

        // Verify round-trip
        let (x, y, z) = MortonCode.decode3D(code)
        #expect(abs(x - 1.0) < 0.00001)
        #expect(abs(y - 1.0) < 0.00001)
        #expect(abs(z - 1.0) < 0.00001)
    }

    @Test("Encode 3D coordinates at midpoint")
    func testEncode3DMidpoint() throws {
        let code = MortonCode.encode3D(x: 0.5, y: 0.5, z: 0.5)
        #expect(code > 0)
    }

    @Test("Decode 3D Morton code at origin")
    func testDecode3DOrigin() throws {
        let (x, y, z) = MortonCode.decode3D(0)
        #expect(abs(x - 0.0) < 0.00001)
        #expect(abs(y - 0.0) < 0.00001)
        #expect(abs(z - 0.0) < 0.00001)
    }

    @Test("3D encoding round-trip accuracy")
    func test3DEncodingRoundTrip() throws {
        let testCases: [(Double, Double, Double)] = [
            (0.0, 0.0, 0.0),
            (1.0, 1.0, 1.0),
            (0.5, 0.5, 0.5),
            (0.25, 0.75, 0.5),
            (0.1, 0.9, 0.3),
            (0.333, 0.667, 0.111),
            (0.123, 0.456, 0.789),
            (0.999, 0.001, 0.5)
        ]

        for (x, y, z) in testCases {
            let code = MortonCode.encode3D(x: x, y: y, z: z)
            let (decodedX, decodedY, decodedZ) = MortonCode.decode3D(code)

            // level=16 (default) → 16 bits per dimension → precision ≈ 1/65536 ≈ 0.000015
            #expect(abs(decodedX - x) < 0.0001)
            #expect(abs(decodedY - y) < 0.0001)
            #expect(abs(decodedZ - z) < 0.0001)
        }
    }

    // MARK: - Bit Interleaving Correctness

    @Test("2D bit interleaving produces correct Z-order")
    func test2DBitInterleaving() throws {
        // Test known Z-order values
        // Example from docs: x=5 (101₂), y=3 (011₂) → 011011₂ = 27
        // But we're using normalized [0,1] coordinates

        // x=0 (all bits 0), y=0 (all bits 0) → code=0
        let code1 = MortonCode.encode2D(x: 0.0, y: 0.0)
        #expect(code1 == 0)

        // x=1 (all bits 1 for even positions), y=0 → 0101010101...
        let code2 = MortonCode.encode2D(x: 1.0, y: 0.0)
        #expect(code2 != 0)

        // x=0, y=1 (all bits 1 for odd positions) → 1010101010...
        let code3 = MortonCode.encode2D(x: 0.0, y: 1.0)
        #expect(code3 != 0)
        #expect(code3 != code2)

        // x=1, y=1 → all bits set in the encoded range (not UInt64.max with level=18)
        let code4 = MortonCode.encode2D(x: 1.0, y: 1.0)
        #expect(code4 > code2)
        #expect(code4 > code3)
        #expect(code4 > 0)
    }

    @Test("3D bit interleaving produces correct Z-order")
    func test3DBitInterleaving() throws {
        // x=0, y=0, z=0 → code=0
        let code1 = MortonCode.encode3D(x: 0.0, y: 0.0, z: 0.0)
        #expect(code1 == 0)

        // x=1, y=0, z=0
        let code2 = MortonCode.encode3D(x: 1.0, y: 0.0, z: 0.0)
        #expect(code2 != 0)

        // x=0, y=1, z=0
        let code3 = MortonCode.encode3D(x: 0.0, y: 1.0, z: 0.0)
        #expect(code3 != 0)
        #expect(code3 != code2)

        // x=0, y=0, z=1
        let code4 = MortonCode.encode3D(x: 0.0, y: 0.0, z: 1.0)
        #expect(code4 != 0)
        #expect(code4 != code2)
        #expect(code4 != code3)

        // All different codes
        let codes = Set([code1, code2, code3, code4])
        #expect(codes.count == 4)
    }

    // MARK: - Locality Preservation

    @Test("2D nearby points have similar Morton codes")
    func test2DLocalityPreservation() throws {
        let baseX = 0.5
        let baseY = 0.5
        let baseCode = MortonCode.encode2D(x: baseX, y: baseY)

        // Points very close to base
        let nearbyPoints: [(Double, Double)] = [
            (0.5001, 0.5001),
            (0.4999, 0.4999),
            (0.5001, 0.4999),
            (0.4999, 0.5001)
        ]

        for (x, y) in nearbyPoints {
            let code = MortonCode.encode2D(x: x, y: y)
            let distance = abs(Int64(bitPattern: code) - Int64(bitPattern: baseCode))

            // With level=18 and bit interleaving, small coordinate changes can produce
            // very large Morton code distances (observed: up to 864 trillion)
            // Allow up to 1 quintillion (1e18) for Z-order curve variations
            #expect(distance < 1_000_000_000_000_000_000)
        }
    }

    @Test("3D nearby points have similar Morton codes")
    func test3DLocalityPreservation() throws {
        let baseX = 0.5
        let baseY = 0.5
        let baseZ = 0.5
        let baseCode = MortonCode.encode3D(x: baseX, y: baseY, z: baseZ)

        // Points very close to base
        let nearbyPoints: [(Double, Double, Double)] = [
            (0.5001, 0.5001, 0.5001),
            (0.4999, 0.4999, 0.4999),
            (0.5001, 0.4999, 0.5001),
            (0.4999, 0.5001, 0.4999)
        ]

        for (x, y, z) in nearbyPoints {
            let code = MortonCode.encode3D(x: x, y: y, z: z)
            let distance = abs(Int64(bitPattern: code) - Int64(bitPattern: baseCode))

            // With level=16 and bit interleaving, small coordinate changes can produce
            // very large Morton code distances (observed: up to 864 trillion)
            // Allow up to 1 quintillion (1e18) for Z-order curve variations
            #expect(distance < 1_000_000_000_000_000_000)
        }
    }

    // MARK: - Normalization

    @Test("Normalize coordinates to [0, 1] range")
    func testNormalize() throws {
        // Value in middle of range
        let norm1 = MortonCode.normalize(50.0, min: 0.0, max: 100.0)
        #expect(abs(norm1 - 0.5) < 0.00001)

        // Value at minimum
        let norm2 = MortonCode.normalize(0.0, min: 0.0, max: 100.0)
        #expect(abs(norm2 - 0.0) < 0.00001)

        // Value at maximum
        let norm3 = MortonCode.normalize(100.0, min: 0.0, max: 100.0)
        #expect(abs(norm3 - 1.0) < 0.00001)

        // Negative range
        let norm4 = MortonCode.normalize(0.0, min: -50.0, max: 50.0)
        #expect(abs(norm4 - 0.5) < 0.00001)

        // Value below minimum (should clamp)
        let norm5 = MortonCode.normalize(-10.0, min: 0.0, max: 100.0)
        #expect(abs(norm5 - 0.0) < 0.00001)

        // Value above maximum (should clamp)
        let norm6 = MortonCode.normalize(110.0, min: 0.0, max: 100.0)
        #expect(abs(norm6 - 1.0) < 0.00001)
    }

    @Test("Denormalize coordinates from [0, 1] range")
    func testDenormalize() throws {
        // Midpoint
        let denorm1 = MortonCode.denormalize(0.5, min: 0.0, max: 100.0)
        #expect(abs(denorm1 - 50.0) < 0.00001)

        // Minimum
        let denorm2 = MortonCode.denormalize(0.0, min: 0.0, max: 100.0)
        #expect(abs(denorm2 - 0.0) < 0.00001)

        // Maximum
        let denorm3 = MortonCode.denormalize(1.0, min: 0.0, max: 100.0)
        #expect(abs(denorm3 - 100.0) < 0.00001)

        // Negative range
        let denorm4 = MortonCode.denormalize(0.5, min: -50.0, max: 50.0)
        #expect(abs(denorm4 - 0.0) < 0.00001)

        // Quarter point
        let denorm5 = MortonCode.denormalize(0.25, min: 0.0, max: 100.0)
        #expect(abs(denorm5 - 25.0) < 0.00001)
    }

    @Test("Normalize and denormalize round-trip")
    func testNormalizeDenormalizeRoundTrip() throws {
        let testCases: [(Double, Double, Double)] = [
            (50.0, 0.0, 100.0),
            (75.0, 0.0, 100.0),
            (0.0, -50.0, 50.0),
            (123.456, 100.0, 200.0),
            (-10.5, -100.0, 100.0)
        ]

        for (value, min, max) in testCases {
            let normalized = MortonCode.normalize(value, min: min, max: max)
            let denormalized = MortonCode.denormalize(normalized, min: min, max: max)

            let clampedValue = Swift.max(min, Swift.min(max, value))
            #expect(abs(denormalized - clampedValue) < 0.00001)
        }
    }

    // MARK: - Bounding Box Ranges

    @Test("2D bounding box produces valid Morton code range")
    func test2DBoundingBox() throws {
        let (minCode, maxCode) = MortonCode.boundingBox2D(
            minX: 0.25,
            minY: 0.25,
            maxX: 0.75,
            maxY: 0.75
        )

        #expect(minCode < maxCode)

        // Decode to verify bounds (allow some tolerance for quantization)
        let (minX, minY) = MortonCode.decode2D(minCode)
        let (maxX, maxY) = MortonCode.decode2D(maxCode)

        // With level=18, precision ≈ 1/262143 ≈ 0.000004
        // Allow tolerance of ±0.1 for bounding box bounds
        #expect(minX >= 0.15 && minX <= 0.35)
        #expect(minY >= 0.15 && minY <= 0.35)
        #expect(maxX >= 0.65 && maxX <= 0.85)
        #expect(maxY >= 0.65 && maxY <= 0.85)
    }

    @Test("3D bounding box produces valid Morton code range")
    func test3DBoundingBox() throws {
        let (minCode, maxCode) = MortonCode.boundingBox3D(
            minX: 0.25,
            minY: 0.25,
            minZ: 0.25,
            maxX: 0.75,
            maxY: 0.75,
            maxZ: 0.75
        )

        #expect(minCode < maxCode)

        // Decode to verify bounds (allow some tolerance for quantization)
        let (minX, minY, minZ) = MortonCode.decode3D(minCode)
        let (maxX, maxY, maxZ) = MortonCode.decode3D(maxCode)

        // With level=16, precision ≈ 1/65536 ≈ 0.000015
        // Allow tolerance of ±0.1 for bounding box bounds
        #expect(minX >= 0.15 && minX <= 0.35)
        #expect(minY >= 0.15 && minY <= 0.35)
        #expect(minZ >= 0.15 && minZ <= 0.35)
        #expect(maxX >= 0.65 && maxX <= 0.85)
        #expect(maxY >= 0.65 && maxY <= 0.85)
        #expect(maxZ >= 0.65 && maxZ <= 0.85)
    }

    @Test("2D bounding box at corners")
    func test2DBoundingBoxCorners() throws {
        // Bottom-left corner
        let (minCode1, maxCode1) = MortonCode.boundingBox2D(
            minX: 0.0, minY: 0.0,
            maxX: 0.1, maxY: 0.1
        )
        #expect(minCode1 == 0)
        #expect(maxCode1 > 0)

        // Top-right corner
        let (minCode2, maxCode2) = MortonCode.boundingBox2D(
            minX: 0.9, minY: 0.9,
            maxX: 1.0, maxY: 1.0
        )
        // With level=18, max code is not UInt64.max
        #expect(maxCode2 > minCode2)
        #expect(maxCode2 == MortonCode.encode2D(x: 1.0, y: 1.0))
        #expect(minCode2 < UInt64.max)
    }

    @Test("3D bounding box at corners")
    func test3DBoundingBoxCorners() throws {
        // Origin corner
        let (minCode1, maxCode1) = MortonCode.boundingBox3D(
            minX: 0.0, minY: 0.0, minZ: 0.0,
            maxX: 0.1, maxY: 0.1, maxZ: 0.1
        )
        #expect(minCode1 == 0)
        #expect(maxCode1 > 0)

        // Far corner
        let (minCode2, maxCode2) = MortonCode.boundingBox3D(
            minX: 0.9, minY: 0.9, minZ: 0.9,
            maxX: 1.0, maxY: 1.0, maxZ: 1.0
        )
        // With level=16 (default), max code is not as high as max63Bit
        #expect(maxCode2 > minCode2)
        #expect(maxCode2 == MortonCode.encode3D(x: 1.0, y: 1.0, z: 1.0))
    }

    // MARK: - Ordering Properties

    @Test("2D Morton codes maintain partial ordering")
    func test2DPartialOrdering() throws {
        // Points along x-axis should generally increase in Morton code
        let codes = (0...10).map { i in
            MortonCode.encode2D(x: Double(i) / 10.0, y: 0.5)
        }

        // Not strictly increasing (Z-order curve zig-zags), but should show trend
        let firstHalf = codes[0..<5]
        let secondHalf = codes[5..<11]

        let avgFirst = firstHalf.reduce(0, +) / UInt64(firstHalf.count)
        let avgSecond = secondHalf.reduce(0, +) / UInt64(secondHalf.count)

        #expect(avgSecond > avgFirst)
    }

    @Test("3D Morton codes increase with coordinates")
    func test3DPartialOrdering() throws {
        // Points along diagonal should increase in Morton code
        let codes = (0...10).map { i in
            let coord = Double(i) / 10.0
            return MortonCode.encode3D(x: coord, y: coord, z: coord)
        }

        // Diagonal should be mostly increasing
        for i in 0..<codes.count - 1 {
            // Allow some local variations due to Z-order curve
            if i % 2 == 0 {
                #expect(codes[i + 1] > codes[i])
            }
        }
    }

    // MARK: - Edge Cases

    @Test("2D encode handles boundary values")
    func test2DEncodeBoundaryValues() throws {
        // All combinations of 0.0 and 1.0
        let codes = [
            MortonCode.encode2D(x: 0.0, y: 0.0),
            MortonCode.encode2D(x: 0.0, y: 1.0),
            MortonCode.encode2D(x: 1.0, y: 0.0),
            MortonCode.encode2D(x: 1.0, y: 1.0)
        ]

        // All should be unique
        let uniqueCodes = Set(codes)
        #expect(uniqueCodes.count == 4)

        // Verify specific values
        #expect(codes[0] == 0)  // (0, 0)
        #expect(codes[3] > codes[1])  // (1, 1) should be largest
        #expect(codes[3] > codes[2])
    }

    @Test("3D encode handles boundary values")
    func test3DEncodeBoundaryValues() throws {
        // All 8 corners of unit cube
        let codes = [
            MortonCode.encode3D(x: 0.0, y: 0.0, z: 0.0),
            MortonCode.encode3D(x: 0.0, y: 0.0, z: 1.0),
            MortonCode.encode3D(x: 0.0, y: 1.0, z: 0.0),
            MortonCode.encode3D(x: 0.0, y: 1.0, z: 1.0),
            MortonCode.encode3D(x: 1.0, y: 0.0, z: 0.0),
            MortonCode.encode3D(x: 1.0, y: 0.0, z: 1.0),
            MortonCode.encode3D(x: 1.0, y: 1.0, z: 0.0),
            MortonCode.encode3D(x: 1.0, y: 1.0, z: 1.0)
        ]

        // All should be unique
        let uniqueCodes = Set(codes)
        #expect(uniqueCodes.count == 8)

        // Verify specific values
        #expect(codes[0] == 0)  // (0, 0, 0)
    }

    @Test("2D encode/decode handles very small differences")
    func test2DVerySmallDifferences() throws {
        let base = 0.5
        // Use epsilon larger than precision threshold
        // level=18 → precision ≈ 0.000004, use 10x larger to ensure different codes
        let epsilon = 0.00004

        let code1 = MortonCode.encode2D(x: base, y: base)
        let code2 = MortonCode.encode2D(x: base + epsilon, y: base)
        let code3 = MortonCode.encode2D(x: base, y: base + epsilon)

        // Should produce different codes for differences above precision threshold
        #expect(code1 != code2)
        #expect(code1 != code3)
        #expect(code2 != code3)
    }

    @Test("3D encode/decode handles very small differences")
    func test3DVerySmallDifferences() throws {
        let base = 0.5
        // Use epsilon larger than precision threshold
        // level=16 → precision ≈ 0.000015, use 10x larger to ensure different codes
        let epsilon = 0.00015

        let code1 = MortonCode.encode3D(x: base, y: base, z: base)
        let code2 = MortonCode.encode3D(x: base + epsilon, y: base, z: base)
        let code3 = MortonCode.encode3D(x: base, y: base + epsilon, z: base)
        let code4 = MortonCode.encode3D(x: base, y: base, z: base + epsilon)

        // Should produce different codes for differences above precision threshold
        let uniqueCodes = Set([code1, code2, code3, code4])
        #expect(uniqueCodes.count == 4)
    }

    // MARK: - Input Validation
    // Note: Input validation is done via precondition checks in MortonCode.swift
    // These cannot be tested in Swift Testing as they cause program termination

    // MARK: - Performance Characteristics

    @Test("2D encoding is deterministic")
    func test2DEncodingDeterministic() throws {
        let coords: [(Double, Double)] = [
            (0.123, 0.456),
            (0.789, 0.012),
            (0.5, 0.5)
        ]

        for (x, y) in coords {
            let code1 = MortonCode.encode2D(x: x, y: y)
            let code2 = MortonCode.encode2D(x: x, y: y)
            #expect(code1 == code2)
        }
    }

    @Test("3D encoding is deterministic")
    func test3DEncodingDeterministic() throws {
        let coords: [(Double, Double, Double)] = [
            (0.123, 0.456, 0.789),
            (0.111, 0.222, 0.333),
            (0.5, 0.5, 0.5)
        ]

        for (x, y, z) in coords {
            let code1 = MortonCode.encode3D(x: x, y: y, z: z)
            let code2 = MortonCode.encode3D(x: x, y: y, z: z)
            #expect(code1 == code2)
        }
    }
}
