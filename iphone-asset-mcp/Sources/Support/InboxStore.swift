import Foundation

/// 공유 익스텐션이 보내온 항목을 담아 둔다.
///
/// 익스텐션과 앱은 App Group 없이는 컨테이너를 공유할 수 없어서(무료 계정 제약),
/// 익스텐션이 루프백으로 POST 하면 여기서 받아 앱 컨테이너에 쓴다. 즉 이 저장소는
/// 앱 프로세스 안에서만 열린다.
///
/// 형식은 파일 두 개다 — 메타데이터 JSON 과, 있을 때만 만드는 바이너리.
/// 하나의 인덱스 파일에 몰아넣지 않는 이유는 그 파일이 깨지면 전부 잃기 때문이다.
final class InboxStore {

    static let shared = InboxStore()

    private let lock = NSLock()

    private init() {}

    /// Documents/Inbox 는 쓰면 안 된다.
    ///
    /// iOS 가 다른 앱에서 열어 온 문서를 놓아 두는 예약 폴더이고, 앱은 그 안의
    /// 파일을 읽고 지울 수만 있다. 거기에 쓰려다 실패한 것이 HTTP 500 의 정체였다.
    /// Application Support 아래 우리 이름의 폴더를 쓴다 — 사용자에게 보이지도 않고,
    /// 시스템과 이름이 겹치지도 않는다.
    private func inboxDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        let inbox = support.appendingPathComponent("SharedInbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: inbox.path) {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        return inbox
    }

    /// 읽기 경로용. 여기서는 실패해도 빈 목록이면 충분하다.
    private var directoryIfAvailable: URL? { try? inboxDirectory() }

    // MARK: - 쓰기

    /// 항목 하나를 저장하고 id 를 돌려준다.
    ///
    /// 실패를 nil 로 뭉개지 않고 던진다. 호출부가 500 만 내보내면 무엇이 잘못됐는지
    /// 아무 데도 남지 않는다 — 실제로 그래서 한 번 헤맸다.
    @discardableResult
    func add(kind: String,
             text: String?,
             name: String?,
             mimeType: String?,
             note: String?,
             data: Data?) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let directory = try inboxDirectory()

        // 시간 + 난수. 같은 밀리초에 여러 장이 들어와도 부딪히지 않는다.
        let id = String(format: "%.0f-%04x", Date().timeIntervalSince1970 * 1000,
                        Int.random(in: 0..<0xFFFF))

        var meta: [String: Any] = [
            "id": id,
            "kind": kind,
            "receivedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let text { meta["text"] = text }
        if let name { meta["name"] = name }
        if let mimeType { meta["mimeType"] = mimeType }
        // 사용자가 공유하면서 적은 지시. 이게 이 항목의 존재 이유다.
        if let note, !note.isEmpty { meta["note"] = note }

        if let data, !data.isEmpty {
            let binary = directory.appendingPathComponent("\(id).bin")
            try data.write(to: binary, options: .atomic)
            meta["bytes"] = data.count
        }

        let json = directory.appendingPathComponent("\(id).json")
        try JSONUtil.data(meta, pretty: true).write(to: json, options: .atomic)
        return id
    }

    // MARK: - 읽기

    /// 최근 것부터. 본문 텍스트는 미리보기 길이로 자른다.
    func list(limit: Int = 50, previewLength: Int = 200) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }

        return loadAll()
            .prefix(limit)
            .map { meta in
                var row = meta
                if let text = meta["text"] as? String, text.count > previewLength {
                    row["text"] = String(text.prefix(previewLength)) + "…"
                    row["truncated"] = true
                }
                return row
            }
    }

    func metadata(id: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let directory = directoryIfAvailable else { return nil }
        return readMeta(directory.appendingPathComponent("\(id).json"))
    }

    func payload(id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let directory = directoryIfAvailable else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent("\(id).bin"))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadAll().count
    }

    // MARK: - 지우기

    /// id 를 주면 그것만, 없으면 전부. 지운 개수를 돌려준다.
    @discardableResult
    func remove(id: String? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let directory = directoryIfAvailable else { return 0 }

        let manager = FileManager.default
        var removed = 0

        if let id {
            for suffix in ["json", "bin"] {
                let url = directory.appendingPathComponent("\(id).\(suffix)")
                if manager.fileExists(atPath: url.path) {
                    try? manager.removeItem(at: url)
                    if suffix == "json" { removed = 1 }
                }
            }
            return removed
        }

        for meta in loadAll() {
            guard let identifier = meta["id"] as? String else { continue }
            for suffix in ["json", "bin"] {
                try? manager.removeItem(at: directory.appendingPathComponent("\(identifier).\(suffix)"))
            }
            removed += 1
        }
        return removed
    }

    // MARK: - 내부

    /// 최근 것이 앞에 오도록 정렬해 전부 읽는다. 잠금은 호출부가 잡는다.
    private func loadAll() -> [[String: Any]] {
        guard let directory = directoryIfAvailable,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }

        return names
            .filter { $0.hasSuffix(".json") }
            .sorted(by: >)   // id 앞부분이 시간이라 문자열 역순이 곧 최신순이다
            .compactMap { readMeta(directory.appendingPathComponent($0)) }
    }

    private func readMeta(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
