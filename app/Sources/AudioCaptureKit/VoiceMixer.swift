@preconcurrency import AVFoundation
import CoreAudio

/// The person's microphone while it feeds a recording: a HAL input IO proc writing into its own ring.
/// A new mic (the call app switched devices) gets a new stream, so blocks never mix sample rates.
final class VoiceStream: @unchecked Sendable {
    let ring = BlockRing(seconds: 6)
    let rate: Double
    let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    /// Test stream: a ring and a rate, no device (used by `VoiceMixer.selfCheck`).
    init(testRate: Double) { rate = testRate; device = 0 }

    init?(device: AudioObjectID, isPaused: @escaping @Sendable () -> Bool) {
        self.device = device
        rate = HAL.f64(device, kAudioDevicePropertyNominalSampleRate) ?? 48_000
        let ring = ring
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil, { _, input, inputTime, _, _ in
            if isPaused() { return }
            _ = ring.write(input, hostTime: inputTime.pointee.mHostTime)
        }) == noErr, let procID else { return nil }
        guard AudioDeviceStart(device, procID) == noErr else { AudioDeviceDestroyIOProcID(device, procID); return nil }
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
    deinit { stop() }
}

/// Writer-thread side of "Include my voice": lines the mic up with the recorded sound by host time and
/// blends it in raw, exactly as the mic delivers it (the macOS input volume is the one control), and
/// watches for the mic hearing the call (speakers). Never touches anything the person hears.
public final class VoiceMixer {
    private let rate: Double
    private var stream: VoiceStream?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat: AVAudioFormat

    // Mono voice at the recording's rate; `queueStart` is the host time (s) of queue[head].
    private var queue: [Float] = []
    private var head = 0
    private var queueStart: Double?

    // Echo (20 ms envelopes, 4 s history): does the mic follow the call?
    private var envFrames = 0, envCall: Float = 0, envVoice: Float = 0
    private var callEnv: [Float] = [], voiceEnv: [Float] = []
    private var envSinceCheck = 0, above = 0, below = 0
    private(set) var echo = false

    init(rate: Double) {
        self.rate = rate
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    /// Follows the stream the recorder currently has (nil: the mic isn't in use, no voice).
    func use(_ s: VoiceStream?) {
        guard s !== stream else { return }
        stream = s
        queue.removeAll(keepingCapacity: true); head = 0; queueStart = nil
        if let s, s.rate != rate {
            inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: s.rate, channels: 1, interleaved: false)
            converter = inFormat.flatMap { AVAudioConverter(from: $0, to: outFormat) }
        } else { inFormat = nil; converter = nil }
    }

    var active: Bool { stream != nil }

    /// Moves everything the mic captured into the queue, resampled and placed by host time.
    func ingest() {
        guard let stream else { return }
        while stream.ring.read({ p, frames, host in
            var mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames { mono[f] = 0.5 * (p[2 * f] + p[2 * f + 1]) }
            let chunk = convert(mono)
            let start = Recorder.seconds(host)
            let pending = queue.count - head
            if let qs = queueStart, pending > 0 {
                let delta = start - (qs + Double(pending) / rate)
                if delta > 0.03 { queue += [Float](repeating: 0, count: Int(delta * rate)) }                 // a real mic gap
                else if delta < -0.03 { queue.removeLast(min(pending, Int(-delta * rate))) }              // clock jitter: re-anchor
            } else {
                queue.removeAll(keepingCapacity: true); head = 0; queueStart = start                      // fresh anchor
            }
            queue += chunk
        }) {}
    }

    /// True once the mic has delivered up to `hostEnd`: the writer waits for this (≤ 250 ms) before writing.
    func covers(_ hostEnd: Double) -> Bool {
        guard let qs = queueStart else { return false }
        return qs + Double(queue.count - head) / rate >= hostEnd
    }

    /// Blends the voice, at `gain`, into one interleaved stereo block that starts at `hostStart`. Returns the voice peak.
    func mix(_ block: UnsafeMutablePointer<Float>, frames: Int, hostStart: Double, cut: Bool, gain: Float = 1) -> Float {
        var voice = [Float](repeating: 0, count: frames)
        if active, let qs = queueStart, queue.count > head {
            // Samples queued before this block are late leftovers: drop them. A queue starting later leaves a silent lead.
            var offset = Int(((hostStart - qs) * rate).rounded())
            let drop = max(0, min(offset, queue.count - head))
            head += drop; offset -= drop
            let start = qs + Double(drop) / rate
            if offset <= 0 {
                let lead = min(-offset, frames)
                let take = min(frames - lead, queue.count - head)
                for i in 0..<take { voice[lead + i] = queue[head + i] }
                head += take
                queueStart = start + Double(take) / rate
            }
            if head > 48_000 { queue.removeFirst(head); head = 0 }
        }
        if cut { for i in 0..<frames { voice[i] = 0 } }
        measure(block, voice, frames: frames, listening: !cut && active)
        var peak: Float = 0
        for f in 0..<frames {
            let v = voice[f] * gain
            peak = max(peak, abs(v))
            block[2 * f] = soft(block[2 * f] + v)
            block[2 * f + 1] = soft(block[2 * f + 1] + v)
        }
        return peak
    }

    /// Only where call + voice together pass −1 dBFS: round the top off instead of clipping. Normal levels are untouched.
    @inline(__always) private func soft(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.89 else { return x }
        return (x < 0 ? -1 : 1) * (0.89 + 0.11 * tanh((a - 0.89) / 0.11))
    }

    private func convert(_ mono: [Float]) -> [Float] {
        guard let converter, let inFormat,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(mono.count)) else { return mono }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        let capacity = AVAudioFrameCount(Double(mono.count) * rate / inFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        _ = converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    private func measure(_ block: UnsafePointer<Float>, _ voice: [Float], frames: Int, listening: Bool) {
        let env = Int(rate * 0.02)
        for f in 0..<frames {
            let c = 0.5 * (block[2 * f] + block[2 * f + 1]), v = voice[f]
            envCall += c * c; envVoice += v * v; envFrames += 1
            if envFrames == env {
                if listening { pushEnvelope(sqrt(envCall / Float(env)), sqrt(envVoice / Float(env))) }
                envFrames = 0; envCall = 0; envVoice = 0
            }
        }
    }

    /// Every second: if the call was present and the mic's envelope follows it (0–200 ms later)
    /// closely, the mic is hearing the call. On after two such seconds, off after two clear ones.
    private func pushEnvelope(_ call: Float, _ voice: Float) {
        callEnv.append(call); voiceEnv.append(voice)
        if callEnv.count > 200 { callEnv.removeFirst(); voiceEnv.removeFirst() }
        envSinceCheck += 1
        guard envSinceCheck >= 50, callEnv.count >= 100 else { return }
        envSinceCheck = 0
        let present = callEnv.filter { $0 > 0.003 }.count
        guard present * 100 >= callEnv.count * 15 else { below += 1; if below >= 2 { echo = false; above = 0 }; return }
        var best: Float = 0
        for lag in 0...10 {
            let n = callEnv.count - lag
            let a = callEnv[0..<n], b = voiceEnv[lag..<(lag + n)]
            let ma = a.reduce(0, +) / Float(n), mb = b.reduce(0, +) / Float(n)
            var s: Float = 0, da: Float = 0, dv: Float = 0
            for i in 0..<n { let x = a[a.startIndex + i] - ma, y = b[b.startIndex + i] - mb; s += x * y; da += x * x; dv += y * y }
            if da > 0, dv > 0 { best = max(best, s / sqrt(da * dv)) }
        }
        if best > 0.5 { above += 1; below = 0; if above >= 2 { echo = true } }
        else if best < 0.35 { below += 1; above = 0; if below >= 2 { echo = false } }
    }
}

extension VoiceMixer {
    /// Device-free check of the voice path: alignment across a different mic rate and jittery
    /// timing, the voice kept at its own level (raw), echo detection on and off. Returns a report.
    public static func selfCheck() -> String {
        let rate = 48_000.0, micRate = 44_100.0, seconds = 40
        var report: [String] = []
        func run(echoCase: Bool, level: Float = 0) -> (gain: Float, echo: Bool, lagMs: Double) {
            let mixer = VoiceMixer(rate: rate)
            let stream = VoiceStream(testRate: micRate)
            mixer.use(stream)
            var outVoice: [Float] = [], inVoiceAt48: [Float] = []
            let block = 512, micBlock = 441
            var micT = 0, tapT = 0
            // "speech": 4 Hz syllables on a tone; call at -26 dBFS speech level, voice at -40 dBFS (−14 dB)
            func env(_ t: Double, _ seed: Double) -> Float { Float(max(0, sin(2 * .pi * (3 + seed) * t)) * max(0, sin(2 * .pi * 0.3 * t + seed))) }
            func call(_ t: Double) -> Float { 0.12 * env(t, 0) * Float(sin(2 * .pi * 220 * t)) }
            func me(_ t: Double) -> Float { echoCase ? 0.5 * call(t - 0.03) : 0.025 * env(t, 0.7) * Float(sin(2 * .pi * 330 * t)) }
            let t0: UInt64 = 1_000_000_000
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            func host(_ s: Double) -> UInt64 { UInt64(Double(t0) + s * 1e9 * Double(tb.denom) / Double(tb.numer)) }
            while tapT < seconds * Int(rate) {
                // mic delivers in its own blocks, slightly ahead, with ±2 ms timestamp jitter
                while Double(micT) / micRate < Double(tapT + block) / rate + 0.02 {
                    var buf = [Float](repeating: 0, count: micBlock)
                    for i in 0..<micBlock { buf[i] = me(Double(micT + i) / micRate) }
                    let jitter = Double((micT / micBlock) % 5 - 2) * 0.0005
                    var abuf = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(micBlock * 4), mData: nil)
                    buf.withUnsafeMutableBufferPointer { bp in
                        abuf.mData = UnsafeMutableRawPointer(bp.baseAddress!)
                        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: abuf)
                        _ = stream.ring.write(&list, hostTime: host(Double(micT) / micRate + jitter))
                    }
                    micT += micBlock
                }
                mixer.ingest()
                let start = Double(tapT) / rate
                var stereo = [Float](repeating: 0, count: block * 2)
                for i in 0..<block { let c = call(Double(tapT + i) / rate); stereo[2 * i] = c; stereo[2 * i + 1] = c }
                let before = stereo
                _ = stereo.withUnsafeMutableBufferPointer { mixer.mix($0.baseAddress!, frames: block, hostStart: Recorder.seconds(host(start)), cut: false, gain: powf(10, level / 20)) }
                for i in 0..<block { outVoice.append(stereo[2 * i] - before[2 * i]); inVoiceAt48.append(me(Double(tapT + i) / rate)) }
                tapT += block
            }
            // alignment: lag between the voice we put in and the voice found in the output (last 10 s)
            let a = Array(inVoiceAt48.suffix(Int(rate) * 10)), b = Array(outVoice.suffix(Int(rate) * 10))
            var best = (lag: 0, c: Float(-1))
            for lag in stride(from: -480, through: 480, by: 4) {
                var s: Float = 0
                for i in stride(from: 600, to: a.count - 600, by: 3) { s += a[i] * b[i + lag] }
                if s > best.c { best = (lag, s) }
            }
            // raw: the voice found in the output should match the voice put in (ratio of RMS, dB)
            func r(_ x: [Float]) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }
            let ratio = 20 * log10(max(r(b), 1e-9) / max(r(a), 1e-9))
            return (ratio, mixer.echo, Double(best.lag) / rate * 1000)
        }
        let normal = run(echoCase: false)
        report.append(String(format: "voice at a different rate (44.1 kHz) with jitter: aligned within %.1f ms; level in the file vs the mic %+.1f dB (raw: expect 0); echo flagged: %@",
                             normal.lagMs, normal.gain, normal.echo ? "YES (wrong)" : "no (right)"))
        for level: Float in [-6, 6] {
            let set = run(echoCase: false, level: level)
            report.append(String(format: "Microphone at %+.0f dB: level in the file vs the mic %+.1f dB (expect %+.0f)", level, set.gain, level))
        }
        let speakers = run(echoCase: true)
        report.append(String(format: "voice = the call heard 30 ms late (speakers): echo flagged: %@",
                             speakers.echo ? "YES (right)" : "no (wrong)"))
        return report.joined(separator: "\n")
    }
}
