import Foundation
import Security

/// 액세스 토큰을 키체인에 보관한다. UserDefaults 는 백업/파일공유로 새어나갈 수 있다.
enum Keychain {

    private static let service = "com.example.assetbridge.token"

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum TokenFactory {

    /// Crockford Base32 — I, L, O, U 를 뺐다. 1/I, 0/O 를 헷갈릴 일이 없다.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 사람이 보고 옮길 수 있는 길이의 토큰. `A3F2-9K7M-QR4X` 형태.
    ///
    /// 12자 × 5비트 = 60비트. 사설망 전용이고 실패 시도에 제동이 걸리는 것을 감안하면
    /// 충분히 넘친다(초당 1만 번 찍어도 평균 수천 년). 43자짜리 base64 토큰은
    /// 눈으로 옮기기엔 지나쳤다.
    static func generate() -> String {
        let raw = randomCharacters(count: 12)
        return stride(from: 0, to: raw.count, by: 4)
            .map { String(raw[raw.index(raw.startIndex, offsetBy: $0)..<raw.index(raw.startIndex, offsetBy: min($0 + 4, raw.count))]) }
            .joined(separator: "-")
    }

    /// 내보내기 링크처럼 사람이 읽지 않는 곳에 쓰는 불투명 키.
    static func opaqueKey(length: Int = 22) -> String {
        randomCharacters(count: length).lowercased()
    }

    private static func randomCharacters(count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        // 256 은 32 로 나누어떨어지므로 % 32 에 편향이 없다.
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// 대시·공백·대소문자를 무시하고 비교할 수 있도록 정규화한다.
    /// 사용자가 `a3f2 9k7m qr4x` 로 쳐도 통과해야 한다.
    static func normalize(_ token: String) -> String {
        token.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 새 형식(정규화 후 12자, 알파벳 안의 문자만)인지.
    /// 예전 43자 base64 토큰을 갈아끼우는 판단에 쓴다.
    static func isCurrentFormat(_ token: String) -> Bool {
        let normalized = normalize(token)
        return normalized.count == 12 && normalized.allSatisfy { alphabet.contains($0) }
    }

    /// 타이밍 공격을 피하기 위한 상수시간 비교. 표기 차이는 먼저 흡수한다.
    static func matches(presented: String, expected: String) -> Bool {
        let a = Array(normalize(presented).utf8)
        let b = Array(normalize(expected).utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}
