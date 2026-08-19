import Foundation

/// 원본 파일 내보내기용 임시 저장소.
/// 도구가 파일을 만들어 등록하면 짧은 키를 돌려주고, `/download/<key>` 로 스트리밍한다.
final class ExportStore {

    static let shared = ExportStore()

    struct Entry {
        let url: URL
        let filename: String
        let byteCount: Int
        let createdAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    let directory: URL

    private init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 확장자를 유지한 채 충돌하지 않는 임시 경로를 만든다.
    func stagingURL(filename: String) -> URL {
        let safe = filename.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(UUID().uuidString)-\(safe)")
    }

    @discardableResult
    func register(url: URL, filename: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let key = TokenFactory.opaqueKey()
        lock.lock()
        entries[key] = Entry(url: url, filename: filename, byteCount: size, createdAt: Date())
        lock.unlock()
        return key
    }

    func entry(for key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    /// 30분 넘은 항목을 지운다. 서버가 요청을 받을 때마다 호출된다.
    func purgeExpired(olderThan interval: TimeInterval = 1800) {
        let cutoff = Date().addingTimeInterval(-interval)
        lock.lock()
        let stale = entries.filter { $0.value.createdAt < cutoff }
        for key in stale.keys { entries.removeValue(forKey: key) }
        lock.unlock()
        for entry in stale.values { try? FileManager.default.removeItem(at: entry.url) }
    }

    func purgeAll() {
        lock.lock()
        let all = entries
        entries.removeAll()
        lock.unlock()
        for entry in all.values { try? FileManager.default.removeItem(at: entry.url) }
    }

    /// 파일 앱에서 꺼낼 수 있도록 Documents/Exports 로 복사한다.
    func copyToDocuments(from url: URL, filename: String) throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
        let exports = documents.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let destination = exports.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
