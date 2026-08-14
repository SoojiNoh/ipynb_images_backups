import CoreLocation
import CoreMotion
import Foundation
import UIKit

// MARK: - Device

final class DeviceProvider: ToolProvider {

    let domain = ToolDomain.device

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "device_info",
            title: "기기 정보",
            description: "모델, iOS 버전, 배터리, 저장 공간, 네트워크 인터페이스, 화면 크기 등 기기 상태 요약.",
            domain: .device
        )
    ]

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        guard name == "device_info" else { throw ToolError("알 수 없는 도구: \(name)") }
        return .json(await info())
    }

    @MainActor
    private func info() -> [String: Any] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        let screen = UIScreen.main.bounds
        let process = ProcessInfo.processInfo

        var payload: [String: Any] = [
            "name": device.name,
            "model": device.model,
            "system": "\(device.systemName) \(device.systemVersion)",
            "identifier": Self.hardwareIdentifier(),
            "screen_points": "\(Int(screen.width))x\(Int(screen.height))",
            "screen_scale": UIScreen.main.scale,
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "uptime_hours": (process.systemUptime / 3600 * 10).rounded() / 10,
            "low_power_mode": process.isLowPowerModeEnabled,
            "thermal_state": Self.thermalName(process.thermalState),
            "processor_count": process.processorCount,
            "physical_memory_gb": (Double(process.physicalMemory) / 1_073_741_824 * 10).rounded() / 10
        ]

        if device.batteryState != .unknown {
            payload["battery_percent"] = Int((device.batteryLevel * 100).rounded())
            payload["battery_state"] = Self.batteryName(device.batteryState)
        }

        if let storage = Self.storage() {
            payload["storage"] = storage
        }

        payload["network_interfaces"] = NetworkInfo.localIPv4Interfaces().map {
            ["name": $0.name, "ip": $0.ip]
        }

        return payload
    }

    private static func hardwareIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier
    }

    private static func storage() -> [String: Any]? {
        guard let url = try? FileManager.default.url(for: .documentDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: false),
              let values = try? url.resourceValues(forKeys: [
                  .volumeAvailableCapacityForImportantUsageKey,
                  .volumeTotalCapacityKey
              ]) else { return nil }

        let gigabyte = 1_073_741_824.0
        var payload: [String: Any] = [:]
        if let total = values.volumeTotalCapacity {
            payload["total_gb"] = (Double(total) / gigabyte * 10).rounded() / 10
        }
        if let free = values.volumeAvailableCapacityForImportantUsage {
            payload["free_gb"] = (Double(free) / gigabyte * 10).rounded() / 10
        }
        return payload.isEmpty ? nil : payload
    }

    private static func batteryName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .charging: return "charging"
        case .full: return "full"
        case .unplugged: return "unplugged"
        default: return "unknown"
        }
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Location

final class LocationProvider: NSObject, ToolProvider, CLLocationManagerDelegate {

    let domain = ToolDomain.location

    private let manager = CLLocationManager()
    private var pending: [CheckedContinuation<CLLocation, Error>] = []
    private let lock = NSLock()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "location_current",
            title: "현재 위치",
            description: """
            기기의 현재 좌표를 가져오고, 원하면 주소로 변환한다.
            위치 권한이 '앱 사용 중'으로 허용되어 있어야 하며 앱이 화면에 떠 있어야 한다.
            """,
            inputSchema: Schema.object([
                "reverse_geocode": Schema.boolean("좌표를 주소 문자열로 변환", defaultValue: true)
            ]),
            domain: .location
        )
    ]

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        guard name == "location_current" else { throw ToolError("알 수 없는 도구: \(name)") }

        switch manager.authorizationStatus {
        case .notDetermined:
            throw ToolError("위치 권한이 아직 요청되지 않았습니다. iPhone 에서 AssetBridge 앱을 열어 허용하세요.")
        case .denied, .restricted:
            throw ToolError("위치 접근이 거부되어 있습니다. 설정 > 개인정보 보호 > 위치 서비스에서 허용하세요.")
        default:
            break
        }

        let location = try await currentLocation()
        var payload: [String: Any] = [
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
            "accuracy_m": (location.horizontalAccuracy * 10).rounded() / 10,
            "altitude_m": (location.altitude * 10).rounded() / 10,
            "timestamp": JSONUtil.value(DateParse.iso8601(location.timestamp))
        ]
        if location.speed >= 0 { payload["speed_mps"] = (location.speed * 10).rounded() / 10 }

        if arguments.bool("reverse_geocode") ?? true {
            if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
                payload["address"] = [
                    "name": JSONUtil.value(placemark.name),
                    "thoroughfare": JSONUtil.value(placemark.thoroughfare),
                    "locality": JSONUtil.value(placemark.locality),
                    "administrative_area": JSONUtil.value(placemark.administrativeArea),
                    "postal_code": JSONUtil.value(placemark.postalCode),
                    "country": JSONUtil.value(placemark.country)
                ]
            }
        }
        return .json(payload)
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    private func currentLocation() async throws -> CLLocation {
        // 최근 값이 충분히 신선하면 재측정하지 않는다.
        if let cached = manager.location, Date().timeIntervalSince(cached.timestamp) < 60 {
            return cached
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending.append(continuation)
            let shouldRequest = pending.count == 1
            lock.unlock()

            if shouldRequest {
                DispatchQueue.main.async { self.manager.requestLocation() }
                // 콜백이 영영 오지 않는 경우를 대비한 안전장치.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    self?.flush(.failure(ToolError("위치 측정 시간이 초과되었습니다.")))
                }
            }
        }
    }

    private func flush(_ result: Result<CLLocation, Error>) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()

        for continuation in waiting {
            switch result {
            case .success(let location): continuation.resume(returning: location)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            flush(.failure(ToolError("위치를 얻지 못했습니다.")))
            return
        }
        flush(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        flush(.failure(ToolError("위치 측정 실패: \(error.localizedDescription)")))
    }
}

// MARK: - Motion

final class MotionProvider: ToolProvider {

    let domain = ToolDomain.motion
    private let pedometer = CMPedometer()

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "motion_activity",
            title: "걸음 · 활동 요약",
            description: """
            기간 동안의 걸음 수, 이동 거리, 오른 층수를 돌려준다.
            iPhone 은 최대 7일치 활동 데이터만 보관한다.
            """,
            inputSchema: Schema.object([
                "start_date": Schema.date("시작 시각. 생략하면 오늘 0시."),
                "end_date": Schema.date("끝 시각. 생략하면 지금."),
                "daily_breakdown": Schema.boolean("하루 단위로 나눠서 집계", defaultValue: false)
            ]),
            domain: .motion
        )
    ]

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        guard name == "motion_activity" else { throw ToolError("알 수 없는 도구: \(name)") }
        guard CMPedometer.isStepCountingAvailable() else {
            throw ToolError("이 기기에서는 걸음 수를 셀 수 없습니다.")
        }
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted:
            throw ToolError("동작 및 피트니스 접근이 거부되어 있습니다. 설정 > 개인정보 보호 > 동작 및 피트니스에서 허용하세요.")
        default:
            break
        }

        let now = Date()
        let start = DateParse.date(from: arguments.string("start_date")) ?? Calendar.current.startOfDay(for: now)
        let end = min(DateParse.endDate(from: arguments.string("end_date")) ?? now, now)
        guard end > start else { throw ToolError("end_date 는 start_date 보다 뒤여야 합니다.") }

        if arguments.bool("daily_breakdown") == true {
            var days: [[String: Any]] = []
            var cursor = Calendar.current.startOfDay(for: start)
            while cursor < end {
                let next = min(Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? end, end)
                var day = try await query(from: cursor, to: next)
                day["date"] = String((DateParse.iso8601(cursor) ?? "").prefix(10))
                days.append(day)
                cursor = next
            }
            return .json(["days": days])
        }

        var payload = try await query(from: start, to: end)
        payload["range"] = ["start": JSONUtil.value(DateParse.iso8601(start)),
                            "end": JSONUtil.value(DateParse.iso8601(end))]
        return .json(payload)
    }

    private func query(from start: Date, to end: Date) async throws -> [String: Any] {
        let data: CMPedometerData = try await withCheckedThrowingContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ToolError(error?.localizedDescription ?? "걸음 데이터를 가져오지 못했습니다."))
                }
            }
        }

        var payload: [String: Any] = ["steps": data.numberOfSteps.intValue]
        if let distance = data.distance { payload["distance_m"] = (distance.doubleValue).rounded() }
        if let floorsUp = data.floorsAscended { payload["floors_up"] = floorsUp.intValue }
        if let floorsDown = data.floorsDescended { payload["floors_down"] = floorsDown.intValue }
        if let pace = data.averageActivePace { payload["avg_pace_s_per_m"] = (pace.doubleValue * 100).rounded() / 100 }
        return payload
    }
}

// MARK: - Clipboard

final class ClipboardProvider: ToolProvider {

    let domain = ToolDomain.clipboard

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "clipboard_read",
            title: "클립보드 읽기",
            description: """
            iPhone 클립보드의 현재 내용을 읽는다. iOS 는 다른 앱이 복사한 내용을 읽을 때
            화면 상단에 붙여넣기 알림 배너를 띄운다.
            """,
            domain: .clipboard
        ),

        MCPTool(
            name: "clipboard_write",
            title: "클립보드 쓰기",
            description: "iPhone 클립보드에 텍스트를 넣는다. 기기에서 바로 붙여넣을 수 있다.",
            inputSchema: Schema.object([
                "text": Schema.string("복사할 텍스트.")
            ], required: ["text"]),
            domain: .clipboard,
            isWrite: true
        )
    ]

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        switch name {
        case "clipboard_read":
            return .json(await read())
        case "clipboard_write":
            guard let text = arguments.string("text") else { throw ToolError("text 가 필요합니다.") }
            await MainActor.run { UIPasteboard.general.string = text }
            return .json(["ok": true, "characters": text.count])
        default:
            throw ToolError("알 수 없는 도구: \(name)")
        }
    }

    @MainActor
    private func read() -> [String: Any] {
        let pasteboard = UIPasteboard.general
        var payload: [String: Any] = ["has_text": pasteboard.hasStrings,
                                      "has_image": pasteboard.hasImages,
                                      "has_url": pasteboard.hasURLs]
        if let text = pasteboard.string {
            payload["text"] = text
            payload["characters"] = text.count
        }
        if let url = pasteboard.url { payload["url"] = url.absoluteString }
        return payload
    }
}
