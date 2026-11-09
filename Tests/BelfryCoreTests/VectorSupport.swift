import Foundation
import XCTest
@testable import BelfryCore

/// vectors/<name>.json, found from this file's path (the repo root is three levels up).
func vector(_ name: String) throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("vectors/\(name).json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func events(_ v: Any?) throws -> [NostrEvent] {
    let data = try JSONSerialization.data(withJSONObject: v ?? [])
    return try JSONDecoder().decode([NostrEvent].self, from: data)
}

func event(_ v: Any?) throws -> NostrEvent {
    let data = try JSONSerialization.data(withJSONObject: v ?? [:])
    return try JSONDecoder().decode(NostrEvent.self, from: data)
}

extension Dictionary where Key == String, Value == Any {
    func dict(_ k: String) -> [String: Any] { self[k] as? [String: Any] ?? [:] }
    func list(_ k: String) -> [[String: Any]] { self[k] as? [[String: Any]] ?? [] }
    func str(_ k: String) -> String? { self[k] as? String }
    func strs(_ k: String) -> [String] { self[k] as? [String] ?? [] }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
}

func tags(_ v: Any?) -> [Tag] { v as? [[String]] ?? [] }
