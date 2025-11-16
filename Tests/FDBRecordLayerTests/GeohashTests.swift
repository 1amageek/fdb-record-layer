import Testing
import Foundation
@testable import FDBRecordLayer

@Suite("Geohash Encoding/Decoding Tests")
struct GeohashTests {

    // MARK: - Basic Encoding/Decoding

    @Test("Encode San Francisco coordinates")
    func testEncodeSanFrancisco() throws {
        // San Francisco: 37.7749° N, 122.4194° W
        let hash = Geohash.encode(latitude: 37.7749, longitude: -122.4194, precision: 7)
        #expect(hash == "9q8yyk8")
    }

    @Test("Encode Tokyo coordinates")
    func testEncodeTokyoCoordinates() throws {
        // Tokyo: 35.6762° N, 139.6503° E
        let hash = Geohash.encode(latitude: 35.6762, longitude: 139.6503, precision: 7)
        #expect(hash == "xn76cyd")
    }

    @Test("Encode London coordinates")
    func testEncodeLondonCoordinates() throws {
        // London: 51.5074° N, 0.1278° W
        let hash = Geohash.encode(latitude: 51.5074, longitude: -0.1278, precision: 7)
        #expect(hash == "gcpvj0d")
    }

    @Test("Decode geohash to bounding box")
    func testDecodeGeohash() throws {
        let bounds = Geohash.decode("9q8yyk8")

        // Verify bounds contain original coordinates
        #expect(bounds.minLat <= 37.7749 && bounds.maxLat >= 37.7749)
        #expect(bounds.minLon <= -122.4194 && bounds.maxLon >= -122.4194)

        // Verify precision (7 chars ≈ ±76mm)
        let latRange = bounds.maxLat - bounds.minLat
        let lonRange = bounds.maxLon - bounds.minLon
        #expect(latRange < 0.002) // < 222m
        #expect(lonRange < 0.003) // < 333m at this latitude
    }

    @Test("Decode center coordinates")
    func testDecodeCenter() throws {
        let (lat, lon) = Geohash.decodeCenter("9q8yyk8")

        // Should be close to San Francisco
        #expect(abs(lat - 37.7749) < 0.001)
        #expect(abs(lon - (-122.4194)) < 0.001)
    }

    @Test("Encoding round-trip accuracy")
    func testEncodingRoundTrip() throws {
        let testCases: [(Double, Double)] = [
            (37.7749, -122.4194),  // San Francisco
            (35.6762, 139.6503),   // Tokyo
            (51.5074, -0.1278),    // London
            (0.0, 0.0),            // Equator/Prime Meridian
            (-33.8688, 151.2093),  // Sydney
            (40.7128, -74.0060)    // New York
        ]

        for (lat, lon) in testCases {
            let hash = Geohash.encode(latitude: lat, longitude: lon, precision: 12)
            let (decodedLat, decodedLon) = Geohash.decodeCenter(hash)

            // Precision 12 should give ±19µm accuracy
            #expect(abs(decodedLat - lat) < 0.00001)
            #expect(abs(decodedLon - lon) < 0.00001)
        }
    }

    // MARK: - Edge Cases

    @Test("Encode coordinates at dateline (180°)")
    func testDatelineEncoding() throws {
        let hash1 = Geohash.encode(latitude: 0.0, longitude: 179.9999, precision: 7)
        let hash2 = Geohash.encode(latitude: 0.0, longitude: -179.9999, precision: 7)

        // Different hashes near dateline
        #expect(hash1 != hash2)

        // Both should decode correctly
        let (lat1, lon1) = Geohash.decodeCenter(hash1)
        let (lat2, lon2) = Geohash.decodeCenter(hash2)

        #expect(abs(lat1) < 0.01)
        #expect(lon1 > 179.0)
        #expect(abs(lat2) < 0.01)
        #expect(lon2 < -179.0)
    }

    @Test("Encode coordinates at poles")
    func testPolarEncoding() throws {
        // North pole
        let northHash = Geohash.encode(latitude: 89.9999, longitude: 0.0, precision: 7)
        let (northLat, _) = Geohash.decodeCenter(northHash)
        #expect(northLat > 89.0)

        // South pole
        let southHash = Geohash.encode(latitude: -89.9999, longitude: 0.0, precision: 7)
        let (southLat, _) = Geohash.decodeCenter(southHash)
        #expect(southLat < -89.0)
    }

    @Test("Encode coordinates at prime meridian")
    func testPrimeMeridianEncoding() throws {
        let hash1 = Geohash.encode(latitude: 51.4778, longitude: 0.0, precision: 7)
        let hash2 = Geohash.encode(latitude: 51.4778, longitude: -0.001, precision: 7)
        let hash3 = Geohash.encode(latitude: 51.4778, longitude: 0.001, precision: 7)

        // Should produce different hashes near 0° with enough distance
        #expect(hash2 != hash3)
    }

    @Test("Encode coordinates at equator")
    func testEquatorEncoding() throws {
        let hash1 = Geohash.encode(latitude: 0.0, longitude: 100.0, precision: 7)
        let hash2 = Geohash.encode(latitude: 0.001, longitude: 100.0, precision: 7)
        let hash3 = Geohash.encode(latitude: -0.001, longitude: 100.0, precision: 7)

        // Should produce different hashes near equator with enough distance
        #expect(hash2 != hash3)
    }

    // MARK: - Precision Levels

    @Test("Different precision levels produce different hash lengths")
    func testPrecisionLevels() throws {
        let lat = 37.7749
        let lon = -122.4194

        for precision in 1...12 {
            let hash = Geohash.encode(latitude: lat, longitude: lon, precision: precision)
            #expect(hash.count == precision)
        }
    }

    @Test("Higher precision produces more specific hash")
    func testPrecisionSpecificity() throws {
        let lat = 37.7749
        let lon = -122.4194

        let hash5 = Geohash.encode(latitude: lat, longitude: lon, precision: 5)
        let hash10 = Geohash.encode(latitude: lat, longitude: lon, precision: 10)

        // Higher precision should be prefix-compatible
        #expect(hash10.hasPrefix(hash5))

        // Decode bounds should be smaller for higher precision
        let bounds5 = Geohash.decode(hash5)
        let bounds10 = Geohash.decode(hash10)

        let range5 = (bounds5.maxLat - bounds5.minLat) * (bounds5.maxLon - bounds5.minLon)
        let range10 = (bounds10.maxLat - bounds10.minLat) * (bounds10.maxLon - bounds10.minLon)

        #expect(range10 < range5)
    }

    // MARK: - Neighbors

    @Test("Calculate north neighbor")
    func testNorthNeighbor() throws {
        let hash = Geohash.encode(latitude: 37.7749, longitude: -122.4194, precision: 5)
        guard let northHash = Geohash.neighbor(hash, direction: .north) else {
            Issue.record("Failed to calculate north neighbor")
            return
        }

        // Just verify that we got a different neighbor
        #expect(northHash != hash)
        #expect(northHash.count == hash.count)
    }

    @Test("Calculate all 8 neighbors")
    func testAllNeighbors() throws {
        let hash = "9q8yyk8"
        let neighbors = Geohash.neighbors(hash)

        // Should have at least 4 neighbors (might be less than 8 due to boundaries)
        #expect(neighbors.count >= 4)
        #expect(neighbors.count <= 8)

        // All neighbors should be valid geohashes of same length
        for neighbor in neighbors {
            #expect(neighbor.count == hash.count)
        }

        // All neighbors should be different from the original hash
        for neighbor in neighbors {
            #expect(neighbor != hash)
        }
    }

    @Test("Neighbors form continuous grid")
    func testNeighborsContinuity() throws {
        let centerHash = Geohash.encode(latitude: 37.7749, longitude: -122.4194, precision: 6)
        let neighbors = Geohash.neighbors(centerHash)

        let centerBounds = Geohash.decode(centerHash)
        let centerArea = (centerBounds.maxLat - centerBounds.minLat) *
                        (centerBounds.maxLon - centerBounds.minLon)

        for neighbor in neighbors {
            let neighborBounds = Geohash.decode(neighbor)
            let neighborArea = (neighborBounds.maxLat - neighborBounds.minLat) *
                              (neighborBounds.maxLon - neighborBounds.minLon)

            // Neighbors should have similar area (within 10% due to projection)
            #expect(abs(neighborArea - centerArea) / centerArea < 0.1)
        }
    }

    // MARK: - Dynamic Precision

    @Test("Optimal precision for large bounding box (country-level)")
    func testOptimalPrecisionCountryLevel() throws {
        let precision = Geohash.optimalPrecision(boundingBoxSizeKm: 1000.0)
        #expect(precision >= 1 && precision <= 3)
    }

    @Test("Optimal precision for city-level bounding box")
    func testOptimalPrecisionCityLevel() throws {
        let precision = Geohash.optimalPrecision(boundingBoxSizeKm: 10.0)
        #expect(precision >= 4 && precision <= 6)
    }

    @Test("Optimal precision for street-level bounding box")
    func testOptimalPrecisionStreetLevel() throws {
        let precision = Geohash.optimalPrecision(boundingBoxSizeKm: 0.1)
        #expect(precision >= 6 && precision <= 8)
    }

    @Test("Optimal precision for building-level bounding box")
    func testOptimalPrecisionBuildingLevel() throws {
        let precision = Geohash.optimalPrecision(boundingBoxSizeKm: 0.001)
        #expect(precision >= 8 && precision <= 12)
    }

    @Test("Bounding box size calculation")
    func testBoundingBoxSizeKm() throws {
        // San Francisco Bay Area: ~50km × 50km
        let size = Geohash.boundingBoxSizeKm(
            minLat: 37.4, maxLat: 37.9,
            minLon: -122.5, maxLon: -122.0
        )

        // Should be approximately 50-60km (max dimension)
        #expect(size > 40.0 && size < 70.0)
    }

    // MARK: - Covering Geohashes

    @Test("Covering geohashes for simple bounding box")
    func testCoveringGeohashesSimple() throws {
        // Small box in San Francisco
        let hashes = Geohash.coveringGeohashes(
            minLat: 37.77,
            minLon: -122.42,
            maxLat: 37.78,
            maxLon: -122.41,
            precision: 6
        )

        // Should return multiple geohashes
        #expect(hashes.count > 0)

        // All hashes should have correct precision
        for hash in hashes {
            #expect(hash.count == 6)
        }

        // Verify coverage: all corners should be covered
        let corners = [
            (37.77, -122.42),
            (37.77, -122.41),
            (37.78, -122.42),
            (37.78, -122.41)
        ]

        for (lat, lon) in corners {
            let cornerHash = Geohash.encode(latitude: lat, longitude: lon, precision: 6)
            #expect(hashes.contains(cornerHash) || hashes.contains { Geohash.neighbors($0).contains(cornerHash) })
        }
    }

    @Test("Covering geohashes with dateline wrapping")
    func testCoveringGeohashesDatelineWrapping() throws {
        // Box crossing dateline (170°E to -170°W)
        let hashes = Geohash.coveringGeohashes(
            minLat: -10.0,
            minLon: 170.0,
            maxLat: 10.0,
            maxLon: -170.0,
            precision: 4
        )

        // Should handle dateline crossing
        #expect(hashes.count > 0)

        // Should cover both sides of dateline
        let westHashes = hashes.filter { hash in
            let (_, lon) = Geohash.decodeCenter(hash)
            return lon > 0
        }
        let eastHashes = hashes.filter { hash in
            let (_, lon) = Geohash.decodeCenter(hash)
            return lon < 0
        }

        #expect(westHashes.count > 0)
        #expect(eastHashes.count > 0)
    }

    @Test("Covering geohashes near poles")
    func testCoveringGeohashesNearPoles() throws {
        // Box near north pole
        let hashes = Geohash.coveringGeohashes(
            minLat: 85.0,
            minLon: -180.0,
            maxLat: 90.0,
            maxLon: 180.0,
            precision: 3
        )

        // Should handle polar region
        #expect(hashes.count > 0)

        // At least some hashes should decode to high latitudes (>= 85.0)
        let highLatHashes = hashes.filter { hash in
            let (lat, _) = Geohash.decodeCenter(hash)
            return lat >= 85.0
        }
        #expect(highLatHashes.count > 0, "Should have at least some hashes in the polar region")

        // Note: Due to neighbor addition for coverage, some hashes may have lower latitudes
    }

    @Test("Covering geohashes for thin bounding box (vertical)")
    func testCoveringGeohashesVerticalThin() throws {
        // Very thin vertical box (0.01° wide)
        let hashes = Geohash.coveringGeohashes(
            minLat: 37.0,
            minLon: -122.0,
            maxLat: 38.0,
            maxLon: -121.99,
            precision: 6
        )

        // Should still provide coverage
        #expect(hashes.count > 0)
    }

    @Test("Covering geohashes for thin bounding box (horizontal)")
    func testCoveringGeohashesHorizontalThin() throws {
        // Very thin horizontal box (0.01° tall)
        let hashes = Geohash.coveringGeohashes(
            minLat: 37.0,
            minLon: -122.0,
            maxLat: 37.01,
            maxLon: -121.0,
            precision: 6
        )

        // Should still provide coverage
        #expect(hashes.count > 0)
    }

    // MARK: - Input Validation
    // Note: Input validation is done via precondition checks in Geohash.swift
    // These cannot be tested in Swift Testing as they cause program termination

    // MARK: - Case Insensitivity

    @Test("Decode handles lowercase and uppercase")
    func testCaseInsensitivity() throws {
        let hashLower = "9q8yyk8"
        let hashUpper = "9Q8YYK8"

        let boundsLower = Geohash.decode(hashLower)
        let boundsUpper = Geohash.decode(hashUpper)

        #expect(boundsLower.minLat == boundsUpper.minLat)
        #expect(boundsLower.maxLat == boundsUpper.maxLat)
        #expect(boundsLower.minLon == boundsUpper.minLon)
        #expect(boundsLower.maxLon == boundsUpper.maxLon)
    }

    // MARK: - Base32 Character Set

    @Test("Encoding produces valid base32 characters")
    func testValidBase32Characters() throws {
        let validChars = Set("0123456789bcdefghjkmnpqrstuvwxyz")

        let testCoords: [(Double, Double)] = [
            (37.7749, -122.4194),
            (0.0, 0.0),
            (51.5074, -0.1278),
            (-33.8688, 151.2093),
            (40.7128, -74.0060)
        ]

        for (lat, lon) in testCoords {
            for precision in 1...12 {
                let hash = Geohash.encode(latitude: lat, longitude: lon, precision: precision)
                for char in hash {
                    #expect(validChars.contains(char))
                }
            }
        }
    }
}
