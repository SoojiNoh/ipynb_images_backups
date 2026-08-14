import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    /// 헤더 이름은 항상 소문자로 정규화한다.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var bearerToken: String? {
        guard let value = header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
}

struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [String: String]
    var body: Data

    /// 큰 파일은 메모리에 올리지 않고 디스크에서 청크로 흘려보낸다.
    var fileURL: URL?
    var fileByteCount: Int = 0

    init(status: Int,
         reason: String? = nil,
         headers: [String: String] = [:],
         body: Data = Data()) {
        self.status = status
        self.reason = reason ?? HTTPResponse.defaultReason(for: status)
        self.headers = headers
        self.body = body
    }

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        var merged = headers
        merged["Content-Type"] = "application/json; charset=utf-8"
        return HTTPResponse(status: status, headers: merged, body: JSONUtil.data(object))
    }

    static func text(_ message: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(message.utf8))
    }

    static func html(_ markup: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "text/html; charset=utf-8"],
                     body: Data(markup.utf8))
    }

    static func empty(status: Int) -> HTTPResponse {
        HTTPResponse(status: status)
    }

    static func file(at url: URL, byteCount: Int, contentType: String, filename: String) -> HTTPResponse {
        var response = HTTPResponse(status: 200, headers: [
            "Content-Type": contentType,
            "Content-Disposition": "attachment; filename=\"\(filename)\""
        ])
        response.fileURL = url
        response.fileByteCount = byteCount
        return response
    }

    /// JSON-RPC 가 아닌 전송 계층 오류(인증 실패 등)를 JSON 으로 돌려준다.
    static func error(_ message: String, status: Int) -> HTTPResponse {
        let body: [String: Any] = ["error": ["code": status, "message": message] as [String: Any]]
        return .json(body, status: status)
    }

    private static func defaultReason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}

enum HTTPTarget {

    /// "/mcp?foo=bar" → ("/mcp", ["foo": "bar"])
    static func split(_ target: String) -> (path: String, query: [String: String]) {
        guard let markIndex = target.firstIndex(of: "?") else {
            return (percentDecoded(target), [:])
        }
        let path = String(target[target.startIndex..<markIndex])
        let rawQuery = String(target[target.index(after: markIndex)...])

        var query: [String: String] = [:]
        for pair in rawQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            query[percentDecoded(String(name))] = percentDecoded(value.replacingOccurrences(of: "+", with: " "))
        }
        return (percentDecoded(path), query)
    }

    static func percentDecoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }
}
