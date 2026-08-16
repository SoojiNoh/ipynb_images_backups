import Foundation
import Network

enum NetworkInfo {

    struct Interface {
        let name: String
        let ip: String

        var isWiFi: Bool { name == "en0" }
    }

    /// 활성화된 IPv4 주소 목록. Wi-Fi(en0)를 앞으로 정렬한다.
    static func localIPv4Interfaces() -> [Interface] {
        var found: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var cursor = head
        while let pointer = cursor {
            let entry = pointer.pointee
            defer { cursor = entry.ifa_next }

            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address,
                                     socklen_t(address.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            found.append(Interface(name: String(cString: entry.ifa_name), ip: String(cString: host)))
        }

        return found.sorted { lhs, rhs in
            if lhs.isWiFi != rhs.isWiFi { return lhs.isWiFi }
            return lhs.name < rhs.name
        }
    }

    static func preferredIPv4() -> String? {
        localIPv4Interfaces().first?.ip
    }

    /// 클라이언트에게 알려줄 호스트. 접속 주소와 다운로드 링크 모두 이걸 써야 한다.
    ///
    /// 시뮬레이터는 Mac 의 네트워크 스택 위에서 돌기 때문에 앱이 여는 포트가
    /// Mac 의 루프백에 열린다. 반면 인터페이스 열거로 나오는 192.0.0.x 는
    /// 시뮬레이터 내부 주소라 Mac 에서 닿지 않으므로 그대로 쓰면 안 된다.
    static func clientReachableHost() -> String {
        #if targetEnvironment(simulator)
        return "127.0.0.1"
        #else
        return preferredIPv4() ?? "127.0.0.1"
        #endif
    }

    /// 들어온 연결의 상대 IP 를 문자열로 뽑는다.
    static func peerAddress(from endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return "\(address)"
            case .ipv6(let address):
                // "fe80::1%en0" 형태에서 존 식별자를 떼어낸다.
                let text = "\(address)"
                if let separator = text.firstIndex(of: "%") { return String(text[text.startIndex..<separator]) }
                return text
            case .name(let name, _):
                return name
            @unknown default:
                return nil
            }
        default:
            return nil
        }
    }

    /// 사설망 / 루프백 / Tailscale(CGNAT) 대역만 허용하기 위한 판정.
    static func isPrivateAddress(_ raw: String) -> Bool {
        var text = raw.lowercased()
        if text.hasPrefix("::ffff:") { text = String(text.dropFirst("::ffff:".count)) }
        if text == "::1" || text == "localhost" { return true }

        let octets = text.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (127, _): return true          // loopback
            case (10, _): return true           // RFC1918
            case (192, 168): return true        // RFC1918
            case (172, 16...31): return true    // RFC1918
            case (169, 254): return true        // link-local
            case (100, 64...127): return true   // CGNAT — Tailscale 등
            default: return false
            }
        }

        // IPv6 링크로컬(fe80::/10) 및 유니크 로컬(fc00::/7)
        return text.hasPrefix("fe80") || text.hasPrefix("fd") || text.hasPrefix("fc")
    }
}
