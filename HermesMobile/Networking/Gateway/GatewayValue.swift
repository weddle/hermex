//
//  GatewayValue.swift
//  HermesMobile
//
//  Type-erased Codable value used for JSON-RPC params/results and dynamic
//  event payloads in the Hermes Agent gateway transport.
//
//  Adapted from hermes-conduit (MIT License), Conduit/Services/HermesClient.swift
//  (enum AnyCodable). Ported for the Hermex fork's native dashboard transport.
//

import Foundation

/// A type-erased, `Codable` JSON value. Used at the gateway boundary so RPC
/// params, results, and event payloads can carry arbitrary shapes without a
/// concrete `Decodable` type in scope. View models never consume this directly;
/// the coordinator maps it into Hermex's concrete models.
enum GatewayValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([GatewayValue])
    case object([String: GatewayValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([GatewayValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: GatewayValue].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .number(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Renders any value as a display string, not just raw strings. Tool
    /// input/output from the gateway often arrives as JSON objects/arrays.
    var descriptiveStringValue: String? {
        switch self {
        case .string(let s): return s
        case .null: return nil
        case .bool(let b): return String(b)
        case .number(let n): return String(n)
        case .array, .object:
            if let data = try? JSONEncoder().encode(self),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return nil
        }
    }

    var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [GatewayValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: GatewayValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Converts a native Swift value into a `GatewayValue`. Used to build RPC
    /// params from Swift dictionaries/arrays.
    static func from(_ value: Any) -> GatewayValue {
        if let v = value as? GatewayValue { return v }
        if value is NSNull { return .null }
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? Int { return .number(Double(v)) }
        if let v = value as? Double { return .number(v) }
        if let v = value as? String { return .string(v) }
        if let v = value as? [Any] { return .array(v.map { GatewayValue.from($0) }) }
        if let v = value as? [String: Any] { return .object(v.mapValues { GatewayValue.from($0) }) }
        return .null
    }
}
