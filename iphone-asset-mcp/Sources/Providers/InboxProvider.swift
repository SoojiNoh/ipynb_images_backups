import Foundation

/// 공유 시트로 보내온 항목을 Claude 에게 노출한다.
///
/// iOS 샌드박스 때문에 다른 앱의 데이터(카카오톡 대화, 문자 등)는 어떤 방법으로도
/// 읽을 수 없다. 사용자가 공유 시트에서 직접 건네준 것만이 유일한 통로이고,
/// 이 도구들이 그 통로의 끝이다.
final class InboxProvider: ToolProvider {

    let domain: ToolDomain = .inbox

    var tools: [MCPTool] {
        [
            MCPTool(
                name: "inbox_list",
                title: "공유 받은 항목 목록",
                description: """
                    사용자가 공유 시트로 AssetBridge 에 보낸 항목을 최근 순으로 봅니다. \
                    카카오톡·사파리·메모 등 어떤 앱에서 보냈든 여기 모입니다. \
                    긴 텍스트는 잘려 나오므로, 전문이 필요하면 inbox_read 를 쓰세요.
                    """,
                inputSchema: Schema.object([
                    "limit": Schema.integer("가져올 개수", minimum: 1, maximum: 200, defaultValue: 50)
                ]),
                domain: .inbox
            ),
            MCPTool(
                name: "inbox_read",
                title: "공유 받은 항목 읽기",
                description: "id 로 항목 하나를 전문/원본으로 읽습니다. 이미지는 그림으로 돌려줍니다.",
                inputSchema: Schema.object([
                    "id": Schema.string("inbox_list 가 준 id")
                ], required: ["id"]),
                domain: .inbox
            ),
            MCPTool(
                name: "inbox_clear",
                title: "공유 받은 항목 지우기",
                description: "id 를 주면 그 항목만, 생략하면 전부 지웁니다.",
                inputSchema: Schema.object([
                    "id": Schema.string("지울 항목의 id. 생략하면 전체 삭제.")
                ]),
                domain: .inbox,
                isWrite: true
            )
        ]
    }

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        switch name {
        case "inbox_list":
            let limit = arguments["limit"] as? Int ?? 50
            let items = InboxStore.shared.list(limit: limit)
            guard !items.isEmpty else {
                return .text("공유 받은 항목이 없습니다. iPhone 의 공유 시트에서 AssetBridge 를 고르면 여기에 쌓입니다.")
            }
            return .json(["count": items.count, "items": items])

        case "inbox_read":
            guard let id = arguments["id"] as? String, !id.isEmpty else {
                throw ToolError("id 가 필요합니다.")
            }
            guard let meta = InboxStore.shared.metadata(id: id) else {
                throw ToolError("그런 항목이 없습니다: \(id)")
            }

            var output = ToolOutput()
            output.addJSON(meta)

            if let data = InboxStore.shared.payload(id: id) {
                let mimeType = meta["mimeType"] as? String ?? "application/octet-stream"
                if mimeType.hasPrefix("image/") {
                    output.addImage(data, mimeType: mimeType)
                } else if let text = String(data: data, encoding: .utf8) {
                    output.addText(text)
                } else {
                    output.addText("바이너리 \(data.count) 바이트 — 텍스트로 읽을 수 없습니다.")
                }
            }
            return output

        case "inbox_clear":
            let id = arguments["id"] as? String
            let removed = InboxStore.shared.remove(id: id?.isEmpty == false ? id : nil)
            return .text(removed > 0 ? "\(removed)개를 지웠습니다." : "지울 항목이 없습니다.")

        default:
            throw ToolError("알 수 없는 도구: \(name)")
        }
    }
}
