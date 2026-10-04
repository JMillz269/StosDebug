import Foundation

struct URLQueryDecoder {
    func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
    
        var dict: [String: String] = [:]
        for item in items {
            guard let value = item.value else { continue }
            dict[URLQueryDecoder.normalize(item.name)] = value  // ← Add 'URLQueryDecoder.' prefix
        }
    
        let decoder = _QueryDecoder(dict: dict)
        return try T(from: decoder)
    }

    static func normalize(_ key: String) -> String {
        key
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}

private struct _QueryDecoder: Decoder {
    let dict: [String: String]
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(_KeyedContainer(dict: dict, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer { fatalError("Unsupported") }
    func singleValueContainer() throws -> SingleValueDecodingContainer { fatalError("Unsupported") }
}

private struct _KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let dict: [String: String]
    var codingPath: [CodingKey]

    var allKeys: [Key] { dict.keys.compactMap { Key(stringValue: $0) } }

    private func raw(_ key: Key) -> String? {
        dict[URLQueryDecoder.normalize(key.stringValue)]
    }

    func contains(_ key: Key) -> Bool { raw(key) != nil }
    func decodeNil(forKey key: Key) -> Bool { raw(key) == nil }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        guard let value = raw(key) else { throw missing(key) }
        return value
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        guard let rawValue = raw(key), let value = Int(rawValue) else { throw missing(key) }
        return value
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        guard let rawValue = raw(key), let value = Bool(rawValue) else { throw missing(key) }
        return value
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        guard let rawValue = raw(key), let value = Double(rawValue) else { throw missing(key) }
        return value
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        guard let rawValue = raw(key) else { throw missing(key) }
        guard let value = rawValue as? T else { throw missing(key) }
        return value
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        raw(key)
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        raw(key).flatMap(Int.init)
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        raw(key).flatMap(Bool.init)
    }

    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        raw(key).flatMap(Double.init)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard let rawValue = raw(key) else { return nil }
        return rawValue as? T
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> { fatalError("Unsupported") }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { fatalError("Unsupported") }
    func superDecoder() throws -> Decoder { fatalError("Unsupported") }
    func superDecoder(forKey key: Key) throws -> Decoder { fatalError("Unsupported") }

    private func missing(_ key: Key) -> DecodingError {
        DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing key '\(key.stringValue)'"))
    }
}

struct EnableJIT: Decodable, Sendable {
    var bundleId: String
    var appName: String?
    var pid: Int?
    var relaunchApp: Bool?
    var forcePID: Bool?
    var script: String?

    var scriptData: Data? {
        if let script {
            return Data(base64Encoded: script)
        } else {
            return nil
        }
    }
}
