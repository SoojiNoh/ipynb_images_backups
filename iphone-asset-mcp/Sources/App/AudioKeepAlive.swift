import AVFoundation
import Foundation
import UIKit

/// iOS 는 앱이 백그라운드로 가면 네트워크 리스너를 곧 정지시킨다.
/// 무음 오디오를 재생하는 동안에는 앱이 살아 있으므로 서버도 계속 응답한다.
/// App Store 심사에서는 거부될 수 있는 방식이며, 개인용 사이드로드를 전제로 한다.
///
/// 재생이 한 번 끊기면 그걸로 끝이라는 게 이 방식의 함정이다. 전화·Siri·다른 앱의
/// 오디오 세션 점유, 미디어 데몬 재시작 — 어느 것이든 재생을 멈추고, 멈춘 뒤에는
/// 아무도 다시 켜 주지 않는다. 사용자는 한참 뒤 "왜 또 끊겼지" 로만 알게 된다.
/// 그래서 끊길 수 있는 경로마다 다시 붙이고, 감시 타이머로 한 번 더 받친다.
final class AudioKeepAlive {

    static let shared = AudioKeepAlive()

    private var player: AVAudioPlayer?
    private var wanted = false
    private var watchdog: Timer?
    private var observing = false

    private init() {}

    var isActive: Bool { player?.isPlaying ?? false }

    func start() {
        wanted = true
        observeOnce()
        resume()
        startWatchdog()
    }

    func stop() {
        wanted = false
        watchdog?.invalidate()
        watchdog = nil
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 재생이 멈춰 있으면 다시 켠다. 이미 돌고 있으면 아무것도 하지 않는다.
    private func resume() {
        guard wanted else { return }
        if let player, player.isPlaying { return }

        do {
            let session = AVAudioSession.sharedInstance()
            // mixWithOthers 라 사용자가 듣던 음악을 끊지 않는다.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let fresh = try AVAudioPlayer(data: Self.silentWAV(seconds: 1))
            fresh.numberOfLoops = -1
            fresh.volume = 0
            fresh.prepareToPlay()
            fresh.play()
            player = fresh
        } catch {
            player = nil
        }
    }

    /// 알림만으로는 모든 중단을 잡지 못한다. 주기적으로 상태를 보고 되살린다.
    /// 오디오 백그라운드 모드가 살아 있는 동안에는 이 타이머도 백그라운드에서 돈다.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.resume()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func observeOnce() {
        guard !observing else { return }
        observing = true

        let center = NotificationCenter.default

        // 전화, Siri, 알람 — 끝나면 곧바로 다시 붙인다.
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            guard AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.resume()
        }

        // 미디어 데몬이 재시작하면 세션과 플레이어가 통째로 무효가 된다. 새로 만든다.
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.player = nil
            self?.resume()
        }

        // 백그라운드에서 조용히 죽었더라도, 앱으로 돌아오는 순간에는 반드시 복구한다.
        center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.resume()
        }
    }

    /// 리소스 파일을 번들에 넣지 않으려고 무음 WAV 를 메모리에서 만든다.
    private static func silentWAV(seconds: Int) -> Data {
        let sampleRate = 8000
        let channels = 1
        let bitsPerSample = 16
        let frameCount = sampleRate * seconds
        let dataBytes = frameCount * channels * bitsPerSample / 8

        var data = Data()

        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataBytes))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)                                                    // PCM 헤더 길이
        appendUInt16(1)                                                     // PCM
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * channels * bitsPerSample / 8))     // byte rate
        appendUInt16(UInt16(channels * bitsPerSample / 8))                  // block align
        appendUInt16(UInt16(bitsPerSample))
        appendASCII("data")
        appendUInt32(UInt32(dataBytes))
        data.append(Data(count: dataBytes))

        return data
    }
}
