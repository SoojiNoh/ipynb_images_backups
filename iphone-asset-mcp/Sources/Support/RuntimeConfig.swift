import Foundation

/// UI(메인 스레드)와 HTTP 서버(백그라운드 큐)가 함께 읽는 설정.
/// @Published 를 서버 쪽에서 직접 읽으면 액터 격리에 걸리므로 락으로 감싼 별도 객체를 둔다.
final class RuntimeConfig {

    static let shared = RuntimeConfig()

    private let lock = NSLock()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let port = "server.port"
        static let lanOnly = "server.lanOnly"
        static let allowWrites = "server.allowWrites"
        static let enabledDomains = "server.enabledDomains"      // 옛 형식. 읽기만 한다.
        static let disabledDomains = "server.disabledDomains"
        static let keepAwake = "server.keepAwake"
        static let backgroundAudio = "server.backgroundAudio"
        static let acceptShares = "server.acceptShares"
        static let autoStart = "server.autoStart"
    }

    private var _token: String
    private var _port: Int
    private var _lanOnly: Bool
    private var _allowWrites: Bool
    private var _enabledDomains: Set<String>
    private var _keepAwake: Bool
    private var _backgroundAudio: Bool
    private var _acceptShares: Bool
    private var _autoStart: Bool

    private init() {
        // 예전 43자 base64 토큰을 쓰던 설치본은 조용히 짧은 형식으로 옮긴다.
        if let existing = Keychain.load(account: "primary"), TokenFactory.isCurrentFormat(existing) {
            _token = existing
        } else {
            let fresh = TokenFactory.generate()
            Keychain.save(fresh, account: "primary")
            _token = fresh
        }

        defaults.register(defaults: [
            Key.port: 8765,
            Key.lanOnly: true,
            Key.allowWrites: true,
            Key.keepAwake: true,
            // 앱을 띄워 둬야만 도는 서버는 쓸모가 반이다. 기본으로 켠다.
            // 무음이고 mixWithOthers 라 듣던 음악을 끊지 않는다. 끄고 싶으면 설정에서.
            Key.backgroundAudio: true,
            Key.acceptShares: true,
            Key.autoStart: true
        ])

        _port = defaults.integer(forKey: Key.port)
        _lanOnly = defaults.bool(forKey: Key.lanOnly)
        _allowWrites = defaults.bool(forKey: Key.allowWrites)
        _keepAwake = defaults.bool(forKey: Key.keepAwake)
        _backgroundAudio = defaults.bool(forKey: Key.backgroundAudio)
        _acceptShares = defaults.bool(forKey: Key.acceptShares)
        _autoStart = defaults.bool(forKey: Key.autoStart)

        // 끈 것을 저장한다. 켠 것을 저장하면 나중에 도메인을 추가할 때마다
        // 기존 설치본에서 그 도메인이 조용히 빠진다 — 사용자는 끈 적도 없는데
        // 도구가 보이지 않고, 어디를 봐야 할지도 알 수 없다.
        let all = Set(ToolDomain.allCases.map(\.rawValue))

        if let disabled = defaults.stringArray(forKey: Key.disabledDomains) {
            _enabledDomains = all.subtracting(disabled)
        } else if let legacy = defaults.stringArray(forKey: Key.enabledDomains) {
            // 옛 형식을 한 번만 옮긴다.
            //
            // 옛 목록에 없다고 전부 "사용자가 껐다" 로 볼 수는 없다. 그 목록이
            // 저장된 뒤에 생긴 도메인도 똑같이 없기 때문이다. 그래서 그 시절에
            // 존재했던 도메인만 후보로 놓고, 그중 빠진 것만 꺼진 것으로 옮긴다.
            let legacySchema: Set<String> = [
                "photos", "contacts", "calendar", "reminders", "location",
                "device", "motion", "clipboard", "music", "files"
            ]
            let disabled = Array(legacySchema.subtracting(legacy))
            defaults.set(disabled, forKey: Key.disabledDomains)
            _enabledDomains = all.subtracting(disabled)
        } else {
            _enabledDomains = all
        }
    }

    // MARK: - Token

    var token: String {
        lock.lock(); defer { lock.unlock() }
        return _token
    }

    func rotateToken() -> String {
        let fresh = TokenFactory.generate()
        Keychain.save(fresh, account: "primary")
        lock.lock(); _token = fresh; lock.unlock()
        return fresh
    }

    // MARK: - Server

    var port: Int {
        get { lock.lock(); defer { lock.unlock() }; return _port }
        set {
            let clamped = max(1024, min(65535, newValue))
            lock.lock(); _port = clamped; lock.unlock()
            defaults.set(clamped, forKey: Key.port)
        }
    }

    var lanOnly: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _lanOnly }
        set {
            lock.lock(); _lanOnly = newValue; lock.unlock()
            defaults.set(newValue, forKey: Key.lanOnly)
        }
    }

    var allowWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allowWrites }
        set {
            lock.lock(); _allowWrites = newValue; lock.unlock()
            defaults.set(newValue, forKey: Key.allowWrites)
        }
    }

    var keepAwake: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _keepAwake }
        set {
            lock.lock(); _keepAwake = newValue; lock.unlock()
            defaults.set(newValue, forKey: Key.keepAwake)
        }
    }

    /// 공유 익스텐션이 보내는 항목을 받을지. 루프백에서만 열리는 경로다.
    var acceptShares: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _acceptShares }
        set {
            lock.lock(); _acceptShares = newValue; lock.unlock()
            defaults.set(newValue, forKey: Key.acceptShares)
        }
    }

    var backgroundAudio: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _backgroundAudio }
        set {
            lock.lock(); _backgroundAudio = newValue; lock.unlock()
            defaults.set(newValue, forKey: Key.backgroundAudio)
        }
    }

    /// 앱을 켜면 서버도 같이 켠다. 서버가 존재 이유인 앱이므로 기본값은 켜짐.
    var autoStart: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _autoStart }
        set {
            lock.lock(); _autoStart = newValue; lock.unlock()
            defaults.set(newValue, forKey: Key.autoStart)
        }
    }

    // MARK: - Domains

    var enabledDomains: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _enabledDomains
    }

    func isEnabled(_ domain: ToolDomain) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabledDomains.contains(domain.rawValue)
    }

    func setEnabled(_ enabled: Bool, for domain: ToolDomain) {
        lock.lock()
        if enabled { _enabledDomains.insert(domain.rawValue) } else { _enabledDomains.remove(domain.rawValue) }
        let disabled = Array(Set(ToolDomain.allCases.map(\.rawValue)).subtracting(_enabledDomains))
        lock.unlock()
        defaults.set(disabled, forKey: Key.disabledDomains)
    }
}

enum ToolDomain: String, CaseIterable, Identifiable {
    case photos
    case contacts
    case calendar
    case reminders
    case location
    case device
    case motion
    case clipboard
    case music
    case files
    case inbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "사진 · 동영상"
        case .contacts: return "연락처"
        case .calendar: return "캘린더"
        case .reminders: return "미리 알림"
        case .location: return "위치"
        case .device: return "기기 정보"
        case .motion: return "걸음 · 활동"
        case .clipboard: return "클립보드"
        case .music: return "음악 보관함"
        case .files: return "파일"
        case .inbox: return "공유 받은 항목"
        }
    }

    var symbol: String {
        switch self {
        case .photos: return "photo.on.rectangle.angled"
        case .contacts: return "person.crop.circle"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .location: return "location"
        case .device: return "iphone"
        case .motion: return "figure.walk"
        case .clipboard: return "doc.on.clipboard"
        case .music: return "music.note"
        case .files: return "folder"
        case .inbox: return "tray.and.arrow.down"
        }
    }
}
