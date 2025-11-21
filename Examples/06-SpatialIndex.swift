// Example 06: Spatial Index (Location-based Services)
// This example demonstrates using spatial indexes for restaurant search
// with geo-spatial queries (radius and bounding box).

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definition

@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])

    @Spatial(
        type: .geo(
            latitude: \.latitude,
            longitude: \.longitude,
            level: 17  // ~600m precision
        ),
        name: "by_location"
    )
    var latitude: Double
    var longitude: Double

    var restaurantID: Int64
    var name: String
    var cuisine: String
    var rating: Double
}

// MARK: - Example Usage

@main
struct SpatialIndexExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)
        let schema = Schema([Restaurant.self])
        let subspace = Subspace(prefix: Tuple("examples", "spatial", "restaurants").pack())
        let store = RecordStore<Restaurant>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        print("📦 RecordStore initialized")

        // Tokyo Station coordinates
        let tokyoStationLat = 35.6812
        let tokyoStationLon = 139.7671

        // Insert sample restaurants around Tokyo Station
        print("\n📝 Inserting sample restaurants...")
        let restaurants = [
            Restaurant(restaurantID: 1, latitude: 35.6810, longitude: 139.7670, name: "Ramen Ichiban", cuisine: "Japanese", rating: 4.5),
            Restaurant(restaurantID: 2, latitude: 35.6815, longitude: 139.7675, name: "Sushi Master", cuisine: "Japanese", rating: 4.8),
            Restaurant(restaurantID: 3, latitude: 35.6805, longitude: 139.7665, name: "Italian Trattoria", cuisine: "Italian", rating: 4.2),
            Restaurant(restaurantID: 4, latitude: 35.6820, longitude: 139.7680, name: "French Bistro", cuisine: "French", rating: 4.6),
            Restaurant(restaurantID: 5, latitude: 35.6800, longitude: 139.7660, name: "Thai Cuisine", cuisine: "Thai", rating: 4.3),
            // Far away restaurant
            Restaurant(restaurantID: 6, latitude: 35.7000, longitude: 139.7800, name: "Distant Cafe", cuisine: "Cafe", rating: 4.0),
        ]

        for restaurant in restaurants {
            try await store.save(restaurant)
        }
        print("✅ Inserted \(restaurants.count) restaurants")

        // MARK: - Radius Search

        print("\n🔍 Restaurants within 1km of Tokyo Station:")
        let nearbyRestaurants = try await store.query(Restaurant.self)
            .withinRadius(
                centerLat: tokyoStationLat,
                centerLon: tokyoStationLon,
                radiusMeters: 1000.0,
                using: "Restaurant_by_location"
            )
            .execute()

        for restaurant in nearbyRestaurants {
            print("  - \(restaurant.name) (\(restaurant.cuisine)) ⭐️ \(restaurant.rating)")
        }

        // MARK: - Bounding Box Search

        print("\n📍 Restaurants in specific area (bounding box):")
        let restaurantsInArea = try await store.query(Restaurant.self)
            .withinBoundingBox(
                minLat: 35.68, maxLat: 35.69,
                minLon: 139.76, maxLon: 139.77,
                using: "Restaurant_by_location"
            )
            .execute()

        for restaurant in restaurantsInArea {
            print("  - \(restaurant.name) at (\(restaurant.latitude), \(restaurant.longitude))")
        }

        // MARK: - Combined Query (Location + Filter)

        print("\n🍣 Japanese restaurants within 1km:")
        let japaneseNearby = try await store.query(Restaurant.self)
            .withinRadius(
                centerLat: tokyoStationLat,
                centerLon: tokyoStationLon,
                radiusMeters: 1000.0,
                using: "Restaurant_by_location"
            )
            .execute()

        let filtered = japaneseNearby.filter { $0.cuisine == "Japanese" }
        for restaurant in filtered {
            print("  - \(restaurant.name) ⭐️ \(restaurant.rating)")
        }

        print("\n🎉 Spatial index example completed!")
    }
}
