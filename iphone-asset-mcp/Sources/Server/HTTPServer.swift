import Foundation
import Network

enum HTTPServerError: LocalizedError {
    case invalidPort(Int)
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): return "사용할 수 없는 포트입니다: \(port)"
        case .listenerFailed(let reason): return "서버를 시작하지 못했습니다: \(reason)"
        }
    }
}

/// Network.framework 기반의 최소 HTTP/1.1 서버.
/// 서드파티 의존성 없이 Xcode 에서 바로 빌드된다.
final class HTTPServer {

    typealias Handler = (HTTPRequest, String?, @escaping (HTTPResponse) -> Void) -> Void

    private let queue = DispatchQueue(label: "com.example.assetbridge.http", qos: .userInitiated)

    /// 상태는 락으로 보호한다. `queue.sync` 를 쓰면 리스너 콜백(같은 큐) 안에서
    /// stop() 을 호출할 때 교착이 생긴다.
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    var handler: Handler?
    var onStateChange: ((String) -> Void)?

    private(set) var port: Int = 0

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    func start(port desiredPort: Int, serviceName: String) throws {
        stop()

        guard let rawPort = UInt16(exactly: desiredPort), let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw HTTPServerError.invalidPort(desiredPort)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw HTTPServerError.listenerFailed(error.localizedDescription)
        }

        // Bonjour 광고는 iOS 의 로컬 네트워크 권한 프롬프트를 띄우는 역할도 겸한다.
        newListener.service = NWListener.Service(name: serviceName, type: "_mcp._tcp")

        newListener.newConnectionHandler = { [weak self] nwConnection in
            self?.accept(nwConnection)
        }

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?("ready")
            case .failed(let error):
                self.onStateChange?("failed: \(error.localizedDescription)")
                self.stop()
            case .cancelled:
                self.onStateChange?("stopped")
            case .waiting(let error):
                self.onStateChange?("waiting: \(error.localizedDescription)")
            default:
                break
            }
        }

        lock.lock()
        listener = newListener
        lock.unlock()

        port = desiredPort
        newListener.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let activeListener = listener
        let activeConnections = Array(connections.values)
        listener = nil
        connections.removeAll()
        lock.unlock()

        activeListener?.cancel()
        for connection in activeConnections { connection.close() }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = HTTPConnection(
            connection: nwConnection,
            queue: queue,
            handler: { [weak self] request, peer, complete in
                guard let handler = self?.handler else {
                    complete(.error("Server is not ready", status: 503))
                    return
                }
                handler(request, peer, complete)
            },
            onClose: { [weak self] closed in
                guard let self else { return }
                self.lock.lock()
                self.connections.removeValue(forKey: ObjectIdentifier(closed))
                self.lock.unlock()
            }
        )

        lock.lock()
        let accepting = listener != nil
        if accepting { connections[ObjectIdentifier(connection)] = connection }
        lock.unlock()

        guard accepting else {
            nwConnection.cancel()
            return
        }
        connection.start()
    }
}
