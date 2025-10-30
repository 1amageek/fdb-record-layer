import Foundation
import FoundationDB

/// Generic serializer for Codable types
///
/// This serializer uses Swift's Codable protocol for serialization.
public struct CodableSerializer<T: Codable & Sendable & Equatable>: RecordSerializer {
    public typealias Record = T

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.encoder = encoder
        self.decoder = decoder
    }

    public func serialize(_ record: T) throws -> FDB.Bytes {
        do {
            let data = try encoder.encode(record)
            return Array(data)
        } catch {
            throw RecordLayerError.serializationFailed("Codable encoding failed: \(error)")
        }
    }

    public func deserialize(_ bytes: FDB.Bytes) throws -> T {
        do {
            let data = Data(bytes)
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RecordLayerError.deserializationFailed("Codable decoding failed: \(error)")
        }
    }
}
