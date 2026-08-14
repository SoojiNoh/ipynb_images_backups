import Foundation

// MARK: - Tool description

struct MCPTool {
    let name: String
    let title: String
    let description: String
    let inputSchema: [String: Any]
    let domain: ToolDomain
    /// 쓰기 도구는 "쓰기 허용" 스위치가 켜져 있을 때만 노출·실행된다.
    let isWrite: Bool

    init(name: String,
         title: String,
         description: String,
         inputSchema: [String: Any] = Schema.object([:]),
         domain: ToolDomain,
         isWrite: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.domain = domain
        self.isWrite = isWrite
    }

    /// `tools/list` 응답 항목.
    var descriptor: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": [
                "title": title,
                "readOnlyHint": !isWrite,
                "destructiveHint": false,
                "openWorldHint": false
            ]
        ]
    }
}

// MARK: - Provider

protocol ToolProvider: AnyObject {
    var domain: ToolDomain { get }
    var tools: [MCPTool] { get }
    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput
}

// MARK: - Result

struct ToolOutput {
    var content: [[String: Any]] = []
    var isError = false

    static func text(_ message: String) -> ToolOutput {
        ToolOutput(content: [["type": "text", "text": message]])
    }

    /// 구조화된 결과는 사람이 읽기 쉬운 JSON 문자열로 담는다.
    /// 파라미터를 `Any` 가 아니라 `[String: Any]` 로 두는 게 중요하다. `Any` 면 호출부의
    /// 이종 딕셔너리 리터럴이 문맥 타입을 못 받아 "heterogeneous collection literal" 오류가 난다.
    static func json(_ object: [String: Any]) -> ToolOutput {
        ToolOutput(content: [["type": "text", "text": JSONUtil.string(object, pretty: true)]])
    }

    static func failure(_ message: String) -> ToolOutput {
        ToolOutput(content: [["type": "text", "text": message]], isError: true)
    }

    mutating func addText(_ message: String) {
        content.append(["type": "text", "text": message])
    }

    mutating func addJSON(_ object: [String: Any]) {
        content.append(["type": "text", "text": JSONUtil.string(object, pretty: true)])
    }

    mutating func addImage(_ data: Data, mimeType: String = "image/jpeg") {
        content.append([
            "type": "image",
            "data": data.base64EncodedString(),
            "mimeType": mimeType
        ])
    }

    var payload: [String: Any] {
        ["content": content, "isError": isError]
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - JSON Schema helpers

enum Schema {

    static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    static func string(_ description: String,
                       values: [String]? = nil,
                       defaultValue: String? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string", "description": description]
        if let values { schema["enum"] = values }
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    static func integer(_ description: String,
                        minimum: Int? = nil,
                        maximum: Int? = nil,
                        defaultValue: Int? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "integer", "description": description]
        if let minimum { schema["minimum"] = minimum }
        if let maximum { schema["maximum"] = maximum }
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    static func number(_ description: String,
                       minimum: Double? = nil,
                       maximum: Double? = nil,
                       defaultValue: Double? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "number", "description": description]
        if let minimum { schema["minimum"] = minimum }
        if let maximum { schema["maximum"] = maximum }
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    static func boolean(_ description: String, defaultValue: Bool? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "boolean", "description": description]
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    static func stringArray(_ description: String, maxItems: Int? = nil) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "array",
            "description": description,
            "items": ["type": "string"]
        ]
        if let maxItems { schema["maxItems"] = maxItems }
        return schema
    }

    /// 날짜 파라미터는 어디서나 같은 문구를 쓴다.
    static func date(_ description: String) -> [String: Any] {
        string("\(description) ISO 8601 또는 YYYY-MM-DD 형식.")
    }
}
