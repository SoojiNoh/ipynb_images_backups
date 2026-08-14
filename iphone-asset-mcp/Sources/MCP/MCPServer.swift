import Foundation

/// JSON-RPC 2.0 + MCP Streamable HTTP 트랜스포트.
///
/// 이 서버는 상태를 갖지 않으므로 `Mcp-Session-Id` 를 발급하지 않는다.
/// 서버→클라이언트 스트림(SSE)도 제공하지 않기 때문에 `GET /mcp` 는 405 로 답한다.
/// 두 가지 모두 스펙이 허용하는 축약 구현이다.
final class MCPServer {

    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let fallbackProtocolVersion = "2025-06-18"

    enum LogLevel: String {
        case info, warn, error
    }

    private let config: RuntimeConfig
    private let providers: [ToolProvider]

    var onEvent: ((LogLevel, String) -> Void)?

    init(config: RuntimeConfig = .shared, providers: [ToolProvider]) {
        self.config = config
        self.providers = providers
    }

    // MARK: - Tool catalogue

    /// 도메인 스위치와 쓰기 허용 스위치를 반영한 현재 노출 도구 목록.
    var activeTools: [(provider: ToolProvider, tool: MCPTool)] {
        let enabled = config.enabledDomains
        let allowWrites = config.allowWrites
        var result: [(provider: ToolProvider, tool: MCPTool)] = []
        for provider in providers where enabled.contains(provider.domain.rawValue) {
            for tool in provider.tools where allowWrites || !tool.isWrite {
                result.append((provider: provider, tool: tool))
            }
        }
        return result
    }

    var allTools: [MCPTool] {
        providers.flatMap { $0.tools }
    }

    // MARK: - HTTP routing

    func route(_ request: HTTPRequest, peer: String?) async -> HTTPResponse {
        ExportStore.shared.purgeExpired()

        if config.lanOnly, let peer, !NetworkInfo.isPrivateAddress(peer) {
            onEvent?(.warn, "외부 IP(\(peer)) 접속 차단됨")
            return .error("Local network only. 이 서버는 사설망에서만 접속할 수 있습니다.", status: 403)
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return statusPage()

        case ("GET", "/health"):
            let health: [String: Any] = [
                "ok": true,
                "server": "AssetBridge",
                "protocolVersions": Self.supportedProtocolVersions,
                "toolCount": activeTools.count
            ]
            return .json(health)

        case ("POST", "/mcp"):
            guard authorize(request) else { return unauthorized(peer) }
            return await handleRPC(request)

        case ("GET", "/mcp"):
            guard authorize(request) else { return unauthorized(peer) }
            // SSE 스트림을 제공하지 않는 서버는 405 로 응답한다.
            return .error("This server does not offer an SSE stream. POST JSON-RPC to /mcp instead.", status: 405)

        case ("DELETE", "/mcp"):
            guard authorize(request) else { return unauthorized(peer) }
            return .empty(status: 200)

        default:
            if request.method == "GET", request.path.hasPrefix("/download/") {
                guard authorize(request) else { return unauthorized(peer) }
                return download(key: String(request.path.dropFirst("/download/".count)))
            }
            return .error("Not found", status: 404)
        }
    }

    // MARK: - Auth

    private func authorize(_ request: HTTPRequest) -> Bool {
        // 브라우저 프리뷰 편의를 위해 쿼리 토큰도 받는다(로컬망 한정 사용 권장).
        let presented = request.bearerToken ?? request.query["token"]
        guard let presented else { return false }
        return TokenFactory.constantTimeEquals(presented, config.token)
    }

    private func unauthorized(_ peer: String?) -> HTTPResponse {
        onEvent?(.warn, "인증 실패\(peer.map { " (\($0))" } ?? "")")
        let body: [String: Any] = [
            "error": ["code": 401, "message": "Missing or invalid bearer token"] as [String: Any]
        ]
        return .json(body, status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"AssetBridge\""])
    }

    // MARK: - JSON-RPC

    private func handleRPC(_ request: HTTPRequest) async -> HTTPResponse {
        guard let parsed = JSONUtil.parse(request.body) else {
            return .json(Self.errorEnvelope(id: nil, code: -32700, message: "Parse error"), status: 400)
        }

        // 2025-03-26 이하 클라이언트는 배열 배치를 보낼 수 있다.
        if let batch = parsed as? [Any] {
            var responses: [[String: Any]] = []
            for case let message as [String: Any] in batch {
                if let response = await handle(message: message) { responses.append(response) }
            }
            if responses.isEmpty { return .empty(status: 202) }
            return .json(responses)
        }

        guard let message = parsed as? [String: Any] else {
            return .json(Self.errorEnvelope(id: nil, code: -32600, message: "Invalid Request"), status: 400)
        }

        guard let response = await handle(message: message) else {
            return .empty(status: 202)   // 알림(notification)에는 본문 없이 응답한다
        }
        return .json(response)
    }

    /// 반환값이 nil 이면 응답이 필요 없는 알림이다.
    private func handle(message: [String: Any]) async -> [String: Any]? {
        let id = message["id"]
        let isNotification = (id == nil) || (id is NSNull)

        guard let method = message.string("method") else {
            return isNotification ? nil : Self.errorEnvelope(id: id, code: -32600, message: "Missing method")
        }

        if isNotification {
            if method == "notifications/initialized" { onEvent?(.info, "클라이언트 초기화 완료") }
            return nil
        }

        switch method {
        case "initialize":
            return initialize(id: id, params: message.object("params") ?? [:])

        case "ping":
            return Self.resultEnvelope(id: id, result: [:])

        case "tools/list":
            let tools = activeTools.map { $0.tool.descriptor }
            onEvent?(.info, "tools/list → \(tools.count)개")
            return Self.resultEnvelope(id: id, result: ["tools": tools])

        case "tools/call":
            return await callTool(id: id, params: message.object("params") ?? [:])

        // 이 서버는 리소스/프롬프트를 광고하지 않지만, 목록을 묻는 클라이언트를 위해 빈 배열을 돌려준다.
        case "resources/list":
            return Self.resultEnvelope(id: id, result: ["resources": [Any]()])
        case "resources/templates/list":
            return Self.resultEnvelope(id: id, result: ["resourceTemplates": [Any]()])
        case "prompts/list":
            return Self.resultEnvelope(id: id, result: ["prompts": [Any]()])

        case "logging/setLevel":
            return Self.resultEnvelope(id: id, result: [:])

        default:
            return Self.errorEnvelope(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initialize(id: Any?, params: [String: Any]) -> [String: Any] {
        let requested = params.string("protocolVersion")
        let negotiated = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.fallbackProtocolVersion

        let clientName = params.object("clientInfo")?.string("name") ?? "unknown"
        onEvent?(.info, "initialize ← \(clientName) (protocol \(negotiated))")

        return Self.resultEnvelope(id: id, result: [
            "protocolVersion": negotiated,
            "capabilities": [
                "tools": ["listChanged": false]
            ],
            "serverInfo": [
                "name": "assetbridge-ios",
                "title": "iPhone AssetBridge",
                "version": "1.0.0"
            ],
            "instructions": Self.instructions
        ])
    }

    private func callTool(id: Any?, params: [String: Any]) async -> [String: Any] {
        guard let name = params.string("name") else {
            return Self.errorEnvelope(id: id, code: -32602, message: "Missing tool name")
        }
        let arguments = params.object("arguments") ?? [:]

        guard let match = activeTools.first(where: { $0.tool.name == name }) else {
            // 왜 안 보이는지 알려주면 클라이언트가 사용자에게 안내할 수 있다.
            if let known = allTools.first(where: { $0.name == name }) {
                let reason = known.isWrite && !config.allowWrites
                    ? "쓰기 도구가 꺼져 있습니다. 앱에서 '쓰기 허용'을 켜세요."
                    : "'\(known.domain.title)' 도메인이 앱에서 비활성화되어 있습니다."
                onEvent?(.warn, "\(name) 거부됨 — \(reason)")
                return Self.resultEnvelope(id: id, result: ToolOutput.failure(reason).payload)
            }
            return Self.errorEnvelope(id: id, code: -32602, message: "Unknown tool: \(name)")
        }

        let started = Date()
        do {
            let output = try await match.provider.call(name, arguments: arguments)
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            onEvent?(output.isError ? .warn : .info, "\(name) — \(millis)ms")
            return Self.resultEnvelope(id: id, result: output.payload)
        } catch {
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            onEvent?(.error, "\(name) 실패 (\(millis)ms) — \(message)")
            return Self.resultEnvelope(id: id, result: ToolOutput.failure(message).payload)
        }
    }

    // MARK: - Envelopes

    private static func resultEnvelope(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": JSONUtil.value(id), "result": result]
    }

    private static func errorEnvelope(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": JSONUtil.value(id), "error": ["code": code, "message": message]]
    }

    private static let instructions = """
    이 서버는 사용자의 iPhone 에서 직접 실행되며, 기기에 저장된 개인 데이터를 노출합니다.

    사진을 다룰 때:
    - 먼저 photos_search 로 후보를 좁히세요. 목록은 메타데이터만 돌려주므로 저렴합니다.
    - 여러 장을 훑어봐야 하면 photos_view 를 반복 호출하지 말고 photos_contact_sheet 를 쓰세요.
      한 장의 격자 이미지로 최대 30장을 한 번에 볼 수 있습니다.
    - 확대해서 확인할 사진만 photos_view 로 부르세요. max_dimension 은 필요한 만큼만 올리세요.
    - 스크린샷의 글자를 읽어야 하면 photos_read_text(OCR) 가 이미지를 보는 것보다 정확하고 쌉니다.
    - 원본 파일이 필요하면 photos_export 가 인증된 다운로드 URL 을 돌려줍니다.

    일반 원칙:
    - 자산 식별자(asset_id)는 이 기기 안에서만 유효합니다.
    - 개인정보를 다루므로, 읽은 내용을 요약해 사용자에게 확인시키고 필요 이상으로 인용하지 마세요.
    - 쓰기 도구(생성/수정)는 사용자가 명시적으로 요청했을 때만 호출하세요.
    """

    // MARK: - Downloads

    private func download(key: String) -> HTTPResponse {
        guard let entry = ExportStore.shared.entry(for: key),
              FileManager.default.fileExists(atPath: entry.url.path) else {
            return .error("Export not found or expired", status: 404)
        }
        onEvent?(.info, "다운로드 — \(entry.filename)")
        return .file(at: entry.url,
                     byteCount: entry.byteCount,
                     contentType: Self.contentType(for: entry.filename),
                     filename: entry.filename)
    }

    private static func contentType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "json": return "application/json"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Status page

    private func statusPage() -> HTTPResponse {
        let tools = activeTools.map { $0.tool }
        let grouped = Dictionary(grouping: tools, by: { $0.domain })
        var rows = ""
        for domain in ToolDomain.allCases {
            guard let list = grouped[domain], !list.isEmpty else { continue }
            let names = list.map { "<code>\($0.name)</code>" }.joined(separator: " ")
            rows += "<tr><th>\(domain.title)</th><td>\(names)</td></tr>"
        }

        return .html("""
        <!doctype html><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>AssetBridge</title>
        <style>
          body{font:15px -apple-system,system-ui,sans-serif;margin:0;padding:28px;background:#f5f5f7;color:#1d1d1f}
          .card{max-width:720px;margin:auto;background:#fff;border-radius:16px;padding:24px}
          h1{font-size:20px;margin:0 0 4px}
          p{color:#6e6e73;margin:0 0 20px}
          table{border-collapse:collapse;width:100%}
          th{text-align:left;vertical-align:top;padding:8px 12px 8px 0;white-space:nowrap;font-weight:600}
          td{padding:8px 0;border-bottom:1px solid #eee}
          code{background:#f0f0f2;border-radius:5px;padding:1px 6px;font-size:12.5px;display:inline-block;margin:1px 0}
        </style>
        <div class="card">
          <h1>AssetBridge 실행 중</h1>
          <p>MCP 엔드포인트는 <code>POST /mcp</code> 이며 Bearer 토큰이 필요합니다. 도구 \(tools.count)개 노출 중.</p>
          <table>\(rows)</table>
        </div>
        """)
    }
}
