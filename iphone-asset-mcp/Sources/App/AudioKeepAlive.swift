import AVFoundation
import Foundation

/// iOS 는 앱이 백그라운드로 가면 네트워크 리스너를 곧 정지시킨다.
/// 무음 오디오를 재생하면 세션이 유지되지만, 이는 App Store 심사에서
/// 거부될 수 있는 방식이라 기본값은 꺼짐이며 개인용 사이드로드를 전제로 한다.
final class AudioKeepAlive {

    static let shared = AudioKeepAlive()

    private var player: AVAudioPlayer?

    private init() {}

    var isActive: Bool { player?.isPlaying ?? false }

    func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(data: Self.silentWAV(seconds: 1))
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            player = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
