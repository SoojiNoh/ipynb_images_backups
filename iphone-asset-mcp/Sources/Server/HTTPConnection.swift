import Foundation
import Network

/// HTTP/1.1 커넥션 한 개. keep-alive 를 지원하되 파이프라이닝은 하지 않는다
/// (응답을 다 보낸 뒤에만 다음 요청을 처리한다).
final class HTTPConnection {

    typealias Handler = (HTTPRequest, String?, @escaping (HTTPResponse) -> Void) -> Void

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: Handler
    private let onClose: (HTTPConnection) -> Void

    private var buffer = Data()
    private var isProcessing = false
    private var isClosed = false

    private var fileHandle: FileHandle?
    private var fileKeepAlive = false

    private let maxHeaderBytes = 64 * 1024
    private let maxBodyBytes = 32 * 1024 * 1024
    private let chunkSize = 256 * 1024

    init(connection: NWConnection,
         queue: DispatchQueue,
         handler: @escaping Handler,
         onClose: @escaping (HTTPConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    var peerAddress: String? {
        NetworkInfo.peerAddress(from: connection.endpoint)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? fileHandle?.close()
        fileHandle = nil
        connection.cancel()
        onClose(self)
    }

    // MARK: - Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            if !self.isClosed { self.receive() }
        }
    }

    /// 버퍼에 완결된 요청이 있으면 하나 꺼내 처리한다.
    private func drain() {
        guard !isProcessing, !isClosed else { return }

        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maxHeaderBytes { respond(.text("Header too large", status: 431), keepAlive: false) }
            return
        }

        let headData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else {
            respond(.text("Malformed header", status: 400), keepAlive: false)
            return
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            respond(.text("Malformed request", status: 400), keepAlive: false)
            return
        }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            respond(.text("Malformed request line", status: 400), keepAlive: false)
            return
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            respond(.text("Chunked request bodies are not supported", status: 411), keepAlive: false)
            return
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= maxBodyBytes else {
            respond(.text("Payload too large", status: 413), keepAlive: false)
            return
        }

        let bodyStart = headerRange.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return }   // 아직 다 안 왔다

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let (path, query) = HTTPTarget.split(target)
        let request = HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
        let keepAlive = headers["connection"]?.lowercased() != "close"

        isProcessing = true
        handler(request, peerAddress) { [weak self] response in
            guard let self else { return }
            self.queue.async { self.respond(response, keepAlive: keepAlive) }
        }
    }

    // MARK: - Responding

    private func respond(_ response: HTTPResponse, keepAlive: Bool) {
        guard !isClosed else { return }

        var headers = response.headers
        let isFile = response.fileURL != nil
        headers["Content-Length"] = String(isFile ? response.fileByteCount : response.body.count)
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        headers["Server"] = "AssetBridge"

        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var packet = Data(head.utf8)
        if !isFile { packet.append(response.body) }

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil {
                    self.close()
                } else if let url = response.fileURL {
                    self.beginFileStream(url: url, keepAlive: keepAlive)
                } else {
                    self.finishResponse(keepAlive: keepAlive)
                }
            }
        })
    }

    private func finishResponse(keepAlive: Bool) {
        isProcessing = false
        if keepAlive && !isClosed {
            drain()
        } else {
            close()
        }
    }

    // MARK: - File streaming

    private func beginFileStream(url: URL, keepAlive: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            close()
            return
        }
        fileHandle = handle
        fileKeepAlive = keepAlive
        sendNextFileChunk()
    }

    private func sendNextFileChunk() {
        guard !isClosed, let handle = fileHandle else { return }

        let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            fileHandle = nil
            finishResponse(keepAlive: fileKeepAlive)
            return
        }

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil {
                    try? self.fileHandle?.close()
                    self.fileHandle = nil
                    self.close()
                } else {
                    self.sendNextFileChunk()
                }
            }
        })
    }
}
