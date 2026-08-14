import Foundation
import UniformTypeIdentifiers

/// iOS 앱은 임의 경로를 읽을 수 없다. 접근 가능한 것은
///  1) 앱 자신의 Documents (파일 앱의 "나의 iPhone > AssetBridge"에 노출)
///  2) 사용자가 파일 앱에서 직접 고른 폴더 (보안 스코프 북마크)
/// 뿐이며, 이 프로바이더는 그 두 가지만 다룬다.
final class FileRootStore {

    static let shared = FileRootStore()

    private let defaultsKey = "files.bookmarks"
    private let lock = NSLock()
    private var bookmarks: [String: Data]

    private init() {
        bookmarks = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
    }

    var documentsURL: URL {
        (try? FileManager.default.url(for: .documentDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    func addBookmark(for url: URL) throws {
        let data = try url.bookmarkData(options: [.minimalBookmark],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        lock.lock()
        bookmarks[url.lastPathComponent] = data
        let snapshot = bookmarks
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
    }

    func removeBookmark(named name: String) {
        lock.lock()
        bookmarks.removeValue(forKey: name)
        let snapshot = bookmarks
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
    }

    var bookmarkNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return bookmarks.keys.sorted()
    }

    /// 루트 이름 → 실제 URL. 보안 스코프가 필요한 경우 함께 알려준다.
    func resolve(rootID: String) throws -> (url: URL, needsScope: Bool) {
        if rootID == "documents" { return (documentsURL, false) }

        lock.lock()
        let data = bookmarks[rootID]
        lock.unlock()

        guard let data else {
            throw ToolError("알 수 없는 루트입니다: \(rootID). files_list_roots 로 사용 가능한 루트를 확인하세요.")
        }

        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [],
                          relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        if stale {
            throw ToolError("'\(rootID)' 폴더 접근 권한이 만료되었습니다. 앱에서 폴더를 다시 추가하세요.")
        }
        return (url, true)
    }
}

final class FilesProvider: ToolProvider {

    let domain = ToolDomain.files
    private let store = FileRootStore.shared
    private let maxReadBytes = 512 * 1024

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "files_list_roots",
            title: "접근 가능한 폴더",
            description: """
            읽고 쓸 수 있는 루트 폴더 목록. iOS 샌드박스 때문에 앱 자신의 Documents 와
            사용자가 앱에서 직접 추가한 폴더만 접근할 수 있다.
            """,
            domain: .files
        ),

        MCPTool(
            name: "files_list",
            title: "폴더 내용 보기",
            description: "루트 기준 상대 경로의 파일과 하위 폴더를 나열한다.",
            inputSchema: Schema.object([
                "root": Schema.string("files_list_roots 의 루트 ID.", defaultValue: "documents"),
                "path": Schema.string("루트 기준 상대 경로. 생략하면 루트 자체."),
                "recursive": Schema.boolean("하위 폴더까지 훑는다", defaultValue: false),
                "limit": Schema.integer("최대 항목 수", minimum: 1, maximum: 1000, defaultValue: 200)
            ]),
            domain: .files
        ),

        MCPTool(
            name: "files_read",
            title: "파일 읽기",
            description: """
            파일 내용을 읽는다. 텍스트로 해석되지 않으면 base64 로 돌려준다.
            큰 파일은 앞부분 512KB 까지만 읽는다.
            """,
            inputSchema: Schema.object([
                "root": Schema.string("루트 ID.", defaultValue: "documents"),
                "path": Schema.string("루트 기준 상대 파일 경로."),
                "encoding": Schema.string("강제 인코딩", values: ["auto", "text", "base64"], defaultValue: "auto")
            ], required: ["path"]),
            domain: .files
        ),

        MCPTool(
            name: "files_write",
            title: "파일 쓰기",
            description: "텍스트 파일을 만들거나 덮어쓴다. 상위 폴더는 자동으로 생성된다.",
            inputSchema: Schema.object([
                "root": Schema.string("루트 ID.", defaultValue: "documents"),
                "path": Schema.string("루트 기준 상대 파일 경로."),
                "content": Schema.string("파일에 쓸 텍스트."),
                "append": Schema.boolean("기존 내용 뒤에 덧붙인다", defaultValue: false)
            ], required: ["path", "content"]),
            domain: .files,
            isWrite: true
        )
    ]

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        switch name {
        case "files_list_roots": return listRoots()
        case "files_list": return try list(arguments)
        case "files_read": return try read(arguments)
        case "files_write": return try write(arguments)
        default: throw ToolError("알 수 없는 도구: \(name)")
        }
    }

    // MARK: - Path safety

    /// 상대 경로가 `..` 로 루트를 벗어나지 못하게 막는다.
    private func resolve(_ arguments: [String: Any]) throws -> (url: URL, root: URL, needsScope: Bool) {
        let rootID = arguments.string("root") ?? "documents"
        let (rootURL, needsScope) = try store.resolve(rootID: rootID)

        let relative = (arguments.string("path") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let target = relative.isEmpty
            ? rootURL.standardizedFileURL
            : rootURL.appendingPathComponent(relative).standardizedFileURL

        let rootPath = rootURL.standardizedFileURL.path
        guard target.path == rootPath || target.path.hasPrefix(rootPath + "/") else {
            throw ToolError("루트 폴더 밖의 경로에는 접근할 수 없습니다.")
        }
        return (target, rootURL.standardizedFileURL, needsScope)
    }

    private func withAccess<T>(_ url: URL, needsScope: Bool, _ work: () throws -> T) throws -> T {
        guard needsScope else { return try work() }
        guard url.startAccessingSecurityScopedResource() else {
            throw ToolError("폴더 접근 권한을 얻지 못했습니다. 앱에서 폴더를 다시 추가하세요.")
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try work()
    }

    // MARK: - Tools

    private func listRoots() -> ToolOutput {
        var roots: [[String: Any]] = [[
            "id": "documents",
            "path": store.documentsURL.path,
            "description": "앱 전용 폴더. 파일 앱의 '나의 iPhone > AssetBridge' 에서도 보입니다."
        ]]

        for name in store.bookmarkNames {
            var entry: [String: Any] = ["id": name, "description": "사용자가 추가한 폴더"]
            if let resolved = try? store.resolve(rootID: name) {
                entry["path"] = resolved.url.path
            }
            roots.append(entry)
        }

        return .json([
            "count": roots.count,
            "roots": roots,
            "note": "다른 폴더가 필요하면 iPhone 의 AssetBridge 앱에서 '폴더 추가' 를 눌러 선택하세요."
        ])
    }

    private func list(_ arguments: [String: Any]) throws -> ToolOutput {
        let (target, root, needsScope) = try resolve(arguments)
        let recursive = arguments.bool("recursive") ?? false
        let limit = arguments.clampedInt("limit", default: 200, min: 1, max: 1000)

        return try withAccess(root, needsScope: needsScope) {
            let manager = FileManager.default
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
                throw ToolError("경로를 찾을 수 없습니다: \(target.lastPathComponent)")
            }
            guard isDirectory.boolValue else {
                throw ToolError("폴더가 아닙니다. files_read 를 사용하세요.")
            }

            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            var entries: [[String: Any]] = []

            func describe(_ url: URL) -> [String: Any] {
                let values = try? url.resourceValues(forKeys: Set(keys))
                var payload: [String: Any] = [
                    "name": url.lastPathComponent,
                    "path": String(url.standardizedFileURL.path.dropFirst(root.path.count).drop(while: { $0 == "/" })),
                    "type": (values?.isDirectory ?? false) ? "directory" : "file"
                ]
                if let size = values?.fileSize { payload["bytes"] = size }
                if let modified = values?.contentModificationDate {
                    payload["modified"] = JSONUtil.value(DateParse.iso8601(modified))
                }
                return payload
            }

            if recursive {
                guard let walker = manager.enumerator(at: target,
                                                      includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else {
                    throw ToolError("폴더를 열거하지 못했습니다.")
                }
                for case let url as URL in walker {
                    entries.append(describe(url))
                    if entries.count >= limit { break }
                }
            } else {
                let contents = try manager.contentsOfDirectory(at: target,
                                                               includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
                for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    entries.append(describe(url))
                    if entries.count >= limit { break }
                }
            }

            return .json([
                "root": arguments.string("root") ?? "documents",
                "path": arguments.string("path") ?? "",
                "count": entries.count,
                "entries": entries
            ])
        }
    }

    private func read(_ arguments: [String: Any]) throws -> ToolOutput {
        let (target, root, needsScope) = try resolve(arguments)

        return try withAccess(root, needsScope: needsScope) {
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw ToolError("파일을 찾을 수 없습니다: \(target.lastPathComponent)")
            }

            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            let data = (try handle.read(upToCount: maxReadBytes)) ?? Data()

            let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
            let totalBytes = (attributes?[.size] as? NSNumber)?.intValue ?? data.count

            var payload: [String: Any] = [
                "name": target.lastPathComponent,
                "bytes": totalBytes,
                "truncated": totalBytes > data.count
            ]

            let mode = arguments.string("encoding") ?? "auto"
            if mode != "base64", let text = String(data: data, encoding: .utf8) {
                payload["encoding"] = "text"
                payload["content"] = text
            } else if mode == "text" {
                throw ToolError("이 파일은 UTF-8 텍스트로 읽을 수 없습니다.")
            } else {
                payload["encoding"] = "base64"
                payload["content"] = data.base64EncodedString()
            }

            return .json(payload)
        }
    }

    private func write(_ arguments: [String: Any]) throws -> ToolOutput {
        guard let content = arguments.string("content") else { throw ToolError("content 가 필요합니다.") }
        let (target, root, needsScope) = try resolve(arguments)

        return try withAccess(root, needsScope: needsScope) {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)

            let append = arguments.bool("append") ?? false
            if append, FileManager.default.fileExists(atPath: target.path) {
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(content.utf8))
            } else {
                try Data(content.utf8).write(to: target, options: .atomic)
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
            return .json([
                "ok": true,
                "path": target.path,
                "bytes": (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                "mode": append ? "append" : "overwrite"
            ])
        }
    }
}
