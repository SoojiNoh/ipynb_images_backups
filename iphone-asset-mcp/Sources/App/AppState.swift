import Combine
import Contacts
import CoreLocation
import CoreMotion
import EventKit
import MediaPlayer
import Photos
import SwiftUI
import UIKit

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: MCPServer.LogLevel
    let message: String
}

@MainActor
final class AppState: ObservableObject {

    // MARK: - Providers

    private let photosProvider: PhotosProvider
    private let contactsProvider: ContactsProvider
    private let locationProvider: LocationProvider
    private let motionProvider: MotionProvider
    private let musicProvider: MusicProvider

    private let config: RuntimeConfig
    private let http = HTTPServer()
    private let mcp: MCPServer

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "정지됨"
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var addresses: [NetworkInfo.Interface] = []
    @Published private(set) var toolCount = 0
    @Published private(set) var permissionSummary: [ToolDomain: String] = [:]
    @Published private(set) var fileRoots: [String] = []

    @Published var port: Int { didSet { config.port = port } }
    @Published var lanOnly: Bool { didSet { config.lanOnly = lanOnly } }
    @Published var allowWrites: Bool { didSet { config.allowWrites = allowWrites; refreshToolCount() } }
    @Published var keepAwake: Bool { didSet { config.keepAwake = keepAwake; applyIdleTimer() } }
    @Published var backgroundAudio: Bool { didSet { config.backgroundAudio = backgroundAudio; applyBackgroundAudio() } }
    @Published var enabledDomains: Set<String> {
        didSet {
            for domain in ToolDomain.allCases {
                config.setEnabled(enabledDomains.contains(domain.rawValue), for: domain)
            }
            refreshToolCount()
        }
    }

    var token: String { config.token }

    init() {
        // 권한 요청 등으로 다시 참조해야 하는 프로바이더만 프로퍼티로 남기고,
        // 나머지는 MCP 서버가 소유한다.
        let photos = PhotosProvider()
        let contacts = ContactsProvider()
        let location = LocationProvider()
        let motion = MotionProvider()
        let music = MusicProvider()

        photosProvider = photos
        contactsProvider = contacts
        locationProvider = location
        motionProvider = motion
        musicProvider = music

        let configuration = RuntimeConfig.shared
        config = configuration

        mcp = MCPServer(config: configuration, providers: [
            photos, contacts,
            CalendarProvider(), RemindersProvider(),
            location, DeviceProvider(), motion, ClipboardProvider(),
            music, FilesProvider()
        ])

        port = configuration.port
        lanOnly = configuration.lanOnly
        allowWrites = configuration.allowWrites
        keepAwake = configuration.keepAwake
        backgroundAudio = configuration.backgroundAudio
        enabledDomains = configuration.enabledDomains

        wireServer()
        refreshAddresses()
        refreshToolCount()
        refreshPermissions()
        refreshFileRoots()
        writeConnectionFile()
    }

    /// 시뮬레이터에서만, 접속 정보를 앱 컨테이너에 남긴다.
    ///
    /// 시뮬레이터의 컨테이너는 Mac 디스크에 있으므로 run-simulator.sh 가 이 파일을
    /// 읽어 토큰을 자동으로 등록할 수 있다. 사람이 43자 토큰을 눈으로 옮길 이유가 없다.
    /// 실기기에서는 쓰지 않는다 — 토큰은 키체인에만 두고, 기기에서는 복사 버튼을 쓴다.
    private func writeConnectionFile() {
        #if targetEnvironment(simulator)
        guard let directory = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil,
                                                           create: true) else { return }
        let payload: [String: Any] = [
            "url": endpointURL,
            "token": token,
            "port": port,
            "claude_code_command": claudeCodeCommand
        ]
        try? JSONUtil.data(payload, pretty: true)
            .write(to: directory.appendingPathComponent("connection.json"), options: .atomic)
        #endif
    }

    private func wireServer() {
        let server = mcp
        http.handler = { request, peer, complete in
            // 이 클로저는 @MainActor 컨텍스트에서 만들어지므로 평범한 Task 는 메인 액터를
            // 상속한다. OCR·이미지 인코딩이 메인 스레드를 막지 않도록 detached 로 띄운다.
            Task.detached(priority: .userInitiated) {
                let response = await server.route(request, peer: peer)
                complete(response)
            }
        }
        mcp.onEvent = { [weak self] level, message in
            Task { @MainActor in self?.append(level, message) }
        }
        http.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.statusMessage = Self.describe(state)
                if state.hasPrefix("failed") { self?.isRunning = false }
            }
        }
    }

    private static func describe(_ state: String) -> String {
        switch state {
        case "ready": return "실행 중"
        case "stopped": return "정지됨"
        default: return state
        }
    }

    // MARK: - Server control

    func toggleServer() {
        isRunning ? stop() : start()
    }

    func start() {
        do {
            try http.start(port: port, serviceName: UIDevice.current.name)
            isRunning = true
            statusMessage = "실행 중"
            append(.info, "서버 시작 — 포트 \(port)")
            refreshAddresses()
            writeConnectionFile()
            applyIdleTimer()
            applyBackgroundAudio()
        } catch {
            isRunning = false
            statusMessage = "시작 실패"
            append(.error, error.localizedDescription)
        }
    }

    func stop() {
        http.stop()
        isRunning = false
        statusMessage = "정지됨"
        ExportStore.shared.purgeAll()
        UIApplication.shared.isIdleTimerDisabled = false
        AudioKeepAlive.shared.stop()
        append(.info, "서버 정지")
    }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isRunning && keepAwake
    }

    private func applyBackgroundAudio() {
        if isRunning && backgroundAudio {
            AudioKeepAlive.shared.start()
        } else {
            AudioKeepAlive.shared.stop()
        }
    }

    // MARK: - Connection info

    func refreshAddresses() {
        addresses = NetworkInfo.localIPv4Interfaces()
    }

    var endpointURL: String {
        "http://\(NetworkInfo.clientReachableHost()):\(port)/mcp"
    }

    /// Claude Code 에 붙여넣을 수 있는 한 줄 명령.
    ///
    /// `--transport` 옵션은 비교적 최근 claude CLI 에만 있어서, 조금 옛 버전에서는
    /// "unknown option '--transport'" 로 실패한다. `add-json` 은 그보다 오래
    /// 존재했고 최신 버전에도 그대로 있으므로 이쪽이 넓게 통한다.
    var claudeCodeCommand: String {
        let payload = JSONUtil.string([
            "type": "http",
            "url": endpointURL,
            "headers": ["Authorization": "Bearer \(token)"]
        ] as [String: Any], pretty: false)
        return "claude mcp add-json iphone '\(payload)'"
    }

    /// claude CLI 의 하위 명령에 전혀 의존하지 않는 최후의 수단.
    /// 현재 폴더에 .mcp.json 을 만든다 — Claude Code 가 그 폴더에서 자동으로 읽는다.
    var mcpFileCommand: String {
        "cat > .mcp.json <<'MCPEOF'\n\(mcpJSONConfig)\nMCPEOF"
    }

    /// Claude Desktop 등 설정 파일을 쓰는 클라이언트용 조각.
    var mcpJSONConfig: String {
        let entry: [String: Any] = [
            "type": "http",
            "url": endpointURL,
            "headers": ["Authorization": "Bearer \(token)"]
        ]
        return JSONUtil.string(["mcpServers": ["iphone": entry]], pretty: true)
    }

    /// QR 로 넘길 페이로드. 다른 기기에서 스캔해 설정을 옮길 때 쓴다.
    var pairingPayload: String {
        let payload: [String: String] = [
            "url": endpointURL,
            "token": token,
            "device": UIDevice.current.name
        ]
        return JSONUtil.string(payload, pretty: false)
    }

    func rotateToken() {
        _ = config.rotateToken()
        objectWillChange.send()
        writeConnectionFile()
        append(.warn, "토큰을 새로 발급했습니다. 클라이언트 설정을 갱신하세요.")
    }

    private func refreshToolCount() {
        toolCount = mcp.activeTools.count
    }

    // MARK: - Logging

    private func append(_ level: MCPServer.LogLevel, _ message: String) {
        logs.insert(LogEntry(date: Date(), level: level, message: message), at: 0)
        if logs.count > 300 { logs.removeLast(logs.count - 300) }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Permissions

    func refreshPermissions() {
        var summary: [ToolDomain: String] = [:]

        summary[.photos] = {
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized: return "허용됨"
            case .limited: return "선택한 사진만"
            case .denied: return "거부됨"
            case .restricted: return "제한됨"
            default: return "요청 안 함"
            }
        }()

        summary[.contacts] = Self.describe(CNContactStore.authorizationStatus(for: .contacts).rawValue)
        summary[.calendar] = Self.describeEventKit(EKEventStore.authorizationStatus(for: .event))
        summary[.reminders] = Self.describeEventKit(EKEventStore.authorizationStatus(for: .reminder))

        summary[.location] = {
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways: return "항상 허용"
            case .authorizedWhenInUse: return "앱 사용 중 허용"
            case .denied: return "거부됨"
            case .restricted: return "제한됨"
            default: return "요청 안 함"
            }
        }()

        summary[.motion] = {
            switch CMPedometer.authorizationStatus() {
            case .authorized: return "허용됨"
            case .denied: return "거부됨"
            case .restricted: return "제한됨"
            default: return "요청 안 함"
            }
        }()

        summary[.music] = {
            switch MPMediaLibrary.authorizationStatus() {
            case .authorized: return "허용됨"
            case .denied: return "거부됨"
            case .restricted: return "제한됨"
            default: return "요청 안 함"
            }
        }()

        summary[.device] = "권한 불필요"
        summary[.clipboard] = "권한 불필요"
        summary[.files] = "앱 폴더 + 추가한 폴더"

        permissionSummary = summary
    }

    private static func describe(_ rawStatus: Int) -> String {
        // CNAuthorizationStatus: 0 notDetermined, 1 restricted, 2 denied, 3 authorized, 4 limited(iOS 18+)
        switch rawStatus {
        case 1: return "제한됨"
        case 2: return "거부됨"
        case 3: return "허용됨"
        case 4: return "일부만 허용"
        default: return "요청 안 함"
        }
    }

    private static func describeEventKit(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "허용됨"
        case .writeOnly: return "쓰기 전용"
        case .denied: return "거부됨"
        case .restricted: return "제한됨"
        default: return "요청 안 함"
        }
    }

    /// 모든 도메인의 권한을 순서대로 요청한다. 시스템 시트가 하나씩 뜬다.
    func requestAllPermissions() async {
        await PhotoLibraryService.shared.requestAuthorization()
        await contactsProvider.requestAuthorization()
        await EventKitAccess.requestEvents()
        await EventKitAccess.requestReminders()
        locationProvider.requestAuthorization()
        await musicProvider.requestAuthorization()
        // CoreMotion 은 별도 요청 API 가 없어 첫 조회 때 시트가 뜬다.
        _ = try? await motionProvider.call("motion_activity", arguments: [:])
        refreshPermissions()
    }

    func requestPermission(for domain: ToolDomain) async {
        switch domain {
        case .photos: await PhotoLibraryService.shared.requestAuthorization()
        case .contacts: await contactsProvider.requestAuthorization()
        case .calendar: await EventKitAccess.requestEvents()
        case .reminders: await EventKitAccess.requestReminders()
        case .location: locationProvider.requestAuthorization()
        case .music: await musicProvider.requestAuthorization()
        case .motion: _ = try? await motionProvider.call("motion_activity", arguments: [:])
        case .device, .clipboard, .files: break
        }
        refreshPermissions()
    }

    // MARK: - File roots

    func refreshFileRoots() {
        fileRoots = FileRootStore.shared.bookmarkNames
    }

    func addFileRoot(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileRootStore.shared.addBookmark(for: url)
            append(.info, "폴더 추가 — \(url.lastPathComponent)")
        } catch {
            append(.error, "폴더를 추가하지 못했습니다: \(error.localizedDescription)")
        }
        refreshFileRoots()
    }

    func removeFileRoot(_ name: String) {
        FileRootStore.shared.removeBookmark(named: name)
        refreshFileRoots()
        append(.info, "폴더 제거 — \(name)")
    }
}
