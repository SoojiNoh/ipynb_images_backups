import Foundation

/// JSON-RPC / MCP 페이로드는 스키마가 자유로워서 Codable 대신
/// JSONSerialization + [String: Any] 로 다룬다.
enum JSONUtil {

    static func data(_ object: Any, pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .fragmentsAllowed]
        if pretty {
            options.insert(.prettyPrinted)
            options.insert(.sortedKeys)
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: options) {
            return data
        }
        return Data("{}".utf8)
    }

    static func string(_ object: Any, pretty: Bool = true) -> String {
        String(data: data(object, pretty: pretty), encoding: .utf8) ?? "{}"
    }

    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// JSONSerialization 은 NSNull 만 허용한다. Optional 을 안전하게 넣기 위한 헬퍼.
    static func value(_ optional: Any?) -> Any {
        optional ?? NSNull()
    }
}

extension Dictionary where Key == String, Value == Any {

    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let n = self[key] as? NSNumber { return n.boolValue }
        if let s = self[key] as? String {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    func object(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func array(_ key: String) -> [Any]? {
        self[key] as? [Any]
    }

    /// ["a", "b"] 뿐 아니라 "a,b" 형태도 받아준다. 클라이언트가 배열을 문자열로 보내는 경우가 잦다.
    func stringArray(_ key: String) -> [String]? {
        if let arr = self[key] as? [Any] {
            let mapped = arr.compactMap { $0 as? String }
            return mapped.isEmpty && !arr.isEmpty ? nil : mapped
        }
        if let s = self[key] as? String {
            let parts = s.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        }
        return nil
    }

    /// 정수 파라미터를 범위 안으로 강제한다.
    func clampedInt(_ key: String, default defaultValue: Int, min lower: Int, max upper: Int) -> Int {
        let raw = int(key) ?? defaultValue
        return Swift.max(lower, Swift.min(upper, raw))
    }

    func clampedDouble(_ key: String, default defaultValue: Double, min lower: Double, max upper: Double) -> Double {
        let raw = double(key) ?? defaultValue
        return Swift.max(lower, Swift.min(upper, raw))
    }
}
