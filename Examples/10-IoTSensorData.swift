// Example 10: IoT Sensor Data Management
// This example demonstrates managing IoT sensor data with time-series queries
// and spatial indexing for sensor locations.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definitions

@Recordable
struct SensorReading {
    #PrimaryKey<SensorReading>([\.sensorID, \.timestamp])
    #Index<SensorReading>([\.sensorID, \.timestamp], name: "reading_by_sensor_time")
    #Index<SensorReading>([\.temperature], name: "reading_by_temperature")

    var sensorID: String
    var timestamp: Date
    var temperature: Double
    var humidity: Double
    var pressure: Double
}

@Recordable
struct Sensor {
    #PrimaryKey<Sensor>([\.sensorID])

    @Spatial(
        type: .geo(
            latitude: \.latitude,
            longitude: \.longitude,
            level: 17
        ),
        name: "by_location"
    )
    var latitude: Double
    var longitude: Double

    var sensorID: String
    var location: String
    var installationDate: Date
}

// MARK: - Example Usage

@main
struct IoTSensorDataExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        // SensorReading store
        let readingSchema = Schema([SensorReading.self])
        let readingSubspace = Subspace(prefix: Tuple("examples", "iot", "readings").pack())
        let sensorReadingStore = RecordStore<SensorReading>(
            database: database,
            subspace: readingSubspace,
            schema: readingSchema,
            statisticsManager: NullStatisticsManager()
        )

        // Sensor store
        let sensorSchema = Schema([Sensor.self])
        let sensorSubspace = Subspace(prefix: Tuple("examples", "iot", "sensors").pack())
        let sensorStore = RecordStore<Sensor>(
            database: database,
            subspace: sensorSubspace,
            schema: sensorSchema,
            statisticsManager: NullStatisticsManager()
        )

        print("🌐 IoT sensor platform initialized")

        // MARK: - Register Sensors

        print("\n📡 Registering sensors...")
        let sensors = [
            Sensor(sensorID: "sensor-001", latitude: 35.6812, longitude: 139.7671, location: "Tokyo Station", installationDate: Date()),
            Sensor(sensorID: "sensor-002", latitude: 35.6815, longitude: 139.7675, location: "Tokyo Office A", installationDate: Date()),
            Sensor(sensorID: "sensor-003", latitude: 35.6805, longitude: 139.7665, location: "Tokyo Office B", installationDate: Date()),
        ]

        for sensor in sensors {
            try await sensorStore.save(sensor)
        }
        print("✅ Registered \(sensors.count) sensors")

        // MARK: - Insert Sensor Readings

        print("\n📊 Inserting sensor readings...")
        let calendar = Calendar.current
        let now = Date()

        for hour in 0..<24 {
            let timestamp = calendar.date(byAdding: .hour, value: -hour, to: now)!
            let reading = SensorReading(
                sensorID: "sensor-001",
                timestamp: timestamp,
                temperature: 20.0 + Double.random(in: -5...5),
                humidity: 60.0 + Double.random(in: -10...10),
                pressure: 1013.0 + Double.random(in: -5...5)
            )
            try await sensorReadingStore.save(reading)
        }
        print("✅ Inserted 24 hours of readings for sensor-001")

        // MARK: - Query Recent Readings

        print("\n📈 Fetching last 24 hours of readings for sensor-001...")
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        let readings = try await sensorReadingStore.query()
            .where(\.sensorID, .equals, "sensor-001")
            .where(\.timestamp, .greaterThanOrEqual, yesterday)
            .orderBy(\.timestamp, .ascending)
            .execute()

        if readings.count > 0 {
            let avgTemp = readings.reduce(0.0) { $0 + $1.temperature } / Double(readings.count)
            let avgHumidity = readings.reduce(0.0) { $0 + $1.humidity } / Double(readings.count)

            print("  📊 Statistics:")
            print("    - Average temperature: \(String(format: "%.1f", avgTemp))°C")
            print("    - Average humidity: \(String(format: "%.1f", avgHumidity))%")
            print("    - Total readings: \(readings.count)")
        }

        // MARK: - Temperature Anomaly Detection

        print("\n🚨 Detecting temperature anomalies (>35°C)...")
        let highTempReadings = try await sensorReadingStore.query()
            .where(\.temperature, .greaterThan, 35.0)
            .execute()

        if highTempReadings.isEmpty {
            print("  ✅ No anomalies detected")
        } else {
            for reading in highTempReadings {
                print("  ⚠️ High temperature: \(reading.temperature)°C at \(reading.timestamp)")
            }
        }

        // MARK: - Nearby Sensors

        print("\n📍 Finding sensors within 1km of Tokyo Station...")
        let nearbySensors = try await sensorStore.query(Sensor.self)
            .withinRadius(
                centerLat: 35.6812,
                centerLon: 139.7671,
                radiusMeters: 1000.0,
                using: "Sensor_by_location"
            )
            .execute()

        for sensor in nearbySensors {
            print("  - \(sensor.sensorID): \(sensor.location)")
        }

        print("\n🎉 IoT sensor data example completed!")
    }
}
