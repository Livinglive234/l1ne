import Foundation
import AVFoundation

/// The tones L1ne can play itself while the other phone is ringing, for when the PBX sends none. Generated here, no audio files.
enum RingbackTone: String, CaseIterable, Identifiable {
    case none, us, uk, chime, digital, pulse
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "None (only what the PBX sends)"
        case .us: "Classic phone (North America)"
        case .uk: "Classic phone (UK)"
        case .chime: "Chime"
        case .digital: "Digital"
        case .pulse: "Pulse"
        }
    }
    /// One full cadence: (milliseconds, frequencies in Hz — empty is silence, decays: a plucked note that fades).
    fileprivate var cadence: [(ms: Int, hz: [Double], decay: Bool)] {
        switch self {
        case .none: return []
        case .us: return [(2000, [440, 480], false), (4000, [], false)]
        case .uk: return [(400, [400, 450], false), (200, [], false), (400, [400, 450], false), (2000, [], false)]
        case .chime: return [(260, [1047], true), (260, [1319], true), (700, [1568], true), (2700, [], false)]
        case .digital: return [(90, [1000], false), (90, [], false), (90, [1000], false), (2700, [], false)]
        case .pulse: return [(320, [523], true), (180, [], false), (320, [659], true), (2700, [], false)]
        }
    }

    /// 16 kHz mono 16-bit WAV of one cadence, for looping.
    func wav() -> Data {
        let rate = 16000
        var pcm = [Int16]()
        for seg in cadence {
            let n = rate * seg.ms / 1000
            for i in 0..<n {
                var v = 0.0
                for f in seg.hz { v += sin(2 * .pi * f * Double(i) / Double(rate)) }
                if !seg.hz.isEmpty { v /= Double(seg.hz.count) }
                let t = Double(i) / Double(n)
                var env = seg.decay ? exp(-4.0 * t) : 1.0
                env *= min(1, Double(i) / 160) * min(1, Double(n - i) / 160)       // 10 ms ramps: no clicks
                pcm.append(Int16(v * env * 0.30 * 32767))
            }
        }
        var d = Data()
        func u32(_ x: Int) { var v = UInt32(x).littleEndian; d.append(Data(bytes: &v, count: 4)) }
        func u16(_ x: Int) { var v = UInt16(x).littleEndian; d.append(Data(bytes: &v, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + pcm.count * 2); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(pcm.count * 2)
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

@MainActor
final class RingbackPlayer {
    static let shared = RingbackPlayer()
    private var player: AVAudioPlayer?
    private var playing: RingbackTone?
    private var stopper: Task<Void, Never>?

    func start(_ tone: RingbackTone) {
        guard tone != .none else { stop(); return }
        if playing == tone, player?.isPlaying == true { return }
        stop()
        guard let p = try? AVAudioPlayer(data: tone.wav()) else { return }
        p.numberOfLoops = -1
        p.volume = 1
        p.play()
        player = p; playing = tone
    }

    func stop() { stopper?.cancel(); player?.stop(); player = nil; playing = nil }

    /// Plays a tone for a few seconds, for the picker.
    func preview(_ tone: RingbackTone) {
        let s = AVAudioSession.sharedInstance()
        if SIPEngine.shared.calls.isEmpty { try? s.setCategory(.playback, mode: .default); try? s.setActive(true) }
        start(tone)
        stopper = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.stop() }
        }
    }
}
