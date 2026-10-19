import CoreAudio
import Foundation

/// One recording: a device-free tap → lock-free ring → writer thread → file.
///
/// Threads:
/// - HAL real-time thread: `ring.write` + peak/clip. Nothing else.
/// - writer thread: drains the ring, keeps the file on wall-clock time (pads true
///   gaps with silence), feeds the spectrum, appends to the sink.
/// - caller (main): start / pause / resume / finish, reads published values.
public final class Recorder: @unchecked Sendable {
    public enum Source: Sendable { case everything(excluding: AudioObjectID), app([AudioObjectID]) }

    public let url: URL
    public let format: CaptureFormat
    public private(set) var sampleRate: Double = 48_000

    private var source: Source
    private var device: TapDevice?
    private let ring = BlockRing()
    private let meter = PeakMeter()
    /// State shared with the real-time thread lives in its own object so the IO block captures one reference.
    private final class RTState: @unchecked Sendable {
        let clipped = Atomic<Bool>(false)
        let lastCallback = Atomic<UInt64>(0)
        let paused = Atomic<Bool>(false)
        /// Host time of the last non-zero sample from the tap (or of start/resume, before any).
        let lastSound = Atomic<UInt64>(0)
        let heard = Atomic<Bool>(false)
    }
    private let rt = RTState()
    private let framesWritten = Atomic<Int>(0)
    private let running = Atomic<Bool>(true)
    private let bandsLock = Mutex<[Float]>([Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
    private var writerThread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private var sinkError: Error?
    /// Set by the writer when the file can no longer be written (disk full, drive unplugged).
    private let writeFailedFlag = Atomic<Bool>(false)
    private var lastRetry: UInt64 = 0

    /// "Include my voice": the mic joins this recording (blended in by the writer). Off: nothing changes.
    public let includesVoice: Bool
    private let voiceSlot = Mutex<VoiceStream?>(nil)
    private let voiceCutFlag = Atomic<Bool>(false)
    private let echoFlag = Atomic<Bool>(false)
    private let voiceGainBits = Atomic<UInt64>(UInt64(Float(1).bitPattern))
    private let voiceMeter = PeakMeter()
    private var voiceDevice: AudioObjectID = 0

    public init(source: Source, format: CaptureFormat, url: URL, includesVoice: Bool = false) {
        self.source = source; self.format = format; self.url = url; self.includesVoice = includesVoice
    }

    // MARK: Control (main thread)

    public func start() throws {
        guard let device = makeDevice() else { throw SinkError.setup("tap") }
        self.device = device
        sampleRate = device.sampleRate
        nonisolated(unsafe) let sink = try makeSink(format: format, url: url, sampleRate: sampleRate)   // used only by the writer thread
        let thread = Thread { [unowned self] in
            if self.includesVoice { self.writerLoopWithVoice(sink: sink) } else { self.writerLoop(sink: sink) }
        }
        thread.name = "Audio Capture writer"
        thread.qualityOfService = .userInitiated
        writerThread = thread
        thread.start()
        rt.lastSound.store(mach_absolute_time(), ordering: .relaxed)
        guard startIO(device) else { running.store(false, ordering: .releasing); throw SinkError.setup("io") }
        rt.lastCallback.store(mach_absolute_time(), ordering: .relaxed)   // a tap that never calls back is revived too
    }

    /// Stops capturing without closing the file. Nothing is written while paused.
    public func pause() {
        rt.paused.store(true, ordering: .releasing)
        device?.stop()
        device = nil
        setVoice(device: nil)
    }

    /// False when no tap could be made: the recording stays paused, and can be resumed again.
    @discardableResult
    public func resume(processes: [AudioObjectID]? = nil) -> Bool {
        if let processes, case .app = source { source = .app(processes) }
        guard let device = makeDevice() else { return false }
        self.device = device
        rt.lastSound.store(mach_absolute_time(), ordering: .relaxed)
        rt.paused.store(false, ordering: .releasing)
        guard startIO(device) else {
            rt.paused.store(true, ordering: .releasing)
            device.stop(); self.device = nil
            return false
        }
        rt.lastCallback.store(mach_absolute_time(), ordering: .relaxed)   // a new tap gets the full grace before a stall counts
        return true
    }

    /// A browser or Electron app can spawn new audio processes mid-recording; they join without a gap.
    public func updateProcesses(_ processes: [AudioObjectID]) {
        guard case .app = source else { return }
        source = .app(processes)
        device?.setProcesses(processes)
    }

    /// Rebuilds the tap if the HAL stopped calling back (known macOS 26 failure mode).
    public func reviveIfStalled() {
        guard !rt.paused.load(ordering: .acquiring) else { return }
        guard device != nil else { retryDevice(); return }
        let last = rt.lastCallback.load(ordering: .relaxed)
        guard last != 0, Self.seconds(mach_absolute_time()) - Self.seconds(last) > 1.5 else { return }
        rebuild()
    }

    /// A fresh tap on the same source. The writer turns the short gap into silence, so the file keeps
    /// wall-clock time. Also the cure for a tap that keeps calling back with zeros while the app plays
    /// (seen on macOS 26 after sample-rate switches and AirPods sleep/wake).
    public func rebuild() {
        guard !rt.paused.load(ordering: .acquiring) else { return }
        guard let device else { retryDevice(); return }
        device.stop()
        self.device = nil
        if let fresh = makeDevice() {
            // A tap that won't start isn't kept: the once-a-second retry takes over.
            if startIO(fresh) { self.device = fresh; rt.lastCallback.store(mach_absolute_time(), ordering: .relaxed) } else { fresh.stop() }
        }
    }

    /// A tap that couldn't be made (coreaudiod restarting) is tried again, at most once a second, until it
    /// works; meanwhile the writer keeps time with silence.
    private func retryDevice() {
        let now = mach_absolute_time()
        guard Self.seconds(now) - Self.seconds(lastRetry) >= 1 else { return }
        lastRetry = now
        if let fresh = makeDevice() {
            if startIO(fresh) { device = fresh; rt.lastCallback.store(mach_absolute_time(), ordering: .relaxed) } else { fresh.stop() }
        }
    }

    /// The file can no longer be written: the recording should stop.
    public var writeFailed: Bool { writeFailedFlag.load(ordering: .acquiring) }

    /// Seconds since the tap last delivered a non-zero sample (since start or resume, before any).
    public var secondsSinceSound: Double {
        Self.seconds(mach_absolute_time()) - Self.seconds(rt.lastSound.load(ordering: .relaxed))
    }
    /// Whether the tap has delivered any sound since the recording started.
    public var heardSound: Bool { rt.heard.load(ordering: .relaxed) }

    /// Finalizes the file. Blocks until the writer has flushed (≈ 50 ms for an hour of ALAC).
    public func finish() throws {
        device?.stop()
        device = nil
        setVoice(device: nil)
        running.store(false, ordering: .releasing)
        finished.wait()
        if let sinkError { throw sinkError }
    }

    // MARK: Your voice (main thread)

    /// Follows the mic the recorded app is using (or the system input for Everything); nil stops it.
    public func setVoice(device: AudioObjectID?) {
        guard includesVoice else { return }
        let d = device ?? 0
        guard d != voiceDevice else { return }
        voiceDevice = d
        voiceSlot.withLock { $0 }?.stop()
        voiceSlot.withLock { $0 = nil }
        guard d != 0 else { return }
        let rt = rt
        if let stream = VoiceStream(device: d, isPaused: { rt.paused.load(ordering: .relaxed) }) { voiceSlot.withLock { $0 = stream } }
    }
    public var voiceActive: Bool { voiceSlot.withLock { $0 != nil } }
    public var voiceCut: Bool {
        get { voiceCutFlag.load(ordering: .relaxed) }
        set { voiceCutFlag.store(newValue, ordering: .relaxed) }
    }
    /// The mic is hearing the call (speakers): the recording continues, the window says so.
    public var echoDetected: Bool { echoFlag.load(ordering: .relaxed) }

    /// How loud the microphone is in the file, in dB (0: as recorded). Takes effect from the next block.
    public func setVoiceLevel(decibels: Float) {
        voiceGainBits.store(UInt64(powf(10, decibels / 20).bitPattern), ordering: .relaxed)
    }
    public func takeVoicePeak() -> Float { voiceMeter.take() }

    // MARK: Published values (any thread)

    public var duration: Double { Double(framesWritten.load(ordering: .relaxed)) / sampleRate }
    public var isPaused: Bool { rt.paused.load(ordering: .relaxed) }
    public func takePeak() -> Float { meter.take() }
    public func takeClipped() -> Bool { rt.clipped.exchange(false, ordering: .relaxed) }
    public var bands: [Float] { bandsLock.withLock { $0 } }
    public var secondsSinceLastCallback: Double {
        let last = rt.lastCallback.load(ordering: .relaxed)
        return last == 0 ? 0 : Self.seconds(mach_absolute_time()) - Self.seconds(last)
    }

    // MARK: Internals

    private func makeDevice() -> TapDevice? {
        let desc: CATapDescription
        switch source {
        case .everything(let own): desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own == 0 ? [] : [own])
        case .app(let processes): desc = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        return TapDevice(description: desc, name: "Audio Capture")
    }

    private func startIO(_ device: TapDevice) -> Bool {
        let ring = ring, meter = meter, rt = rt
        return device.start { _, input, inputTime, _, _ in
            if rt.paused.load(ordering: .relaxed) { return }
            let peak = ring.write(input, hostTime: inputTime.pointee.mHostTime)
            meter.report(peak)
            if peak > 0 {
                rt.lastSound.store(inputTime.pointee.mHostTime, ordering: .relaxed)
                rt.heard.store(true, ordering: .relaxed)
            }
            if peak >= 0.999 { rt.clipped.store(true, ordering: .relaxed) }
            rt.lastCallback.store(inputTime.pointee.mHostTime, ordering: .relaxed)
        }
    }

    private static let timebase: Double = { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) / 1e9 }()
    static func seconds(_ host: UInt64) -> Double { Double(host) * timebase }

    private func writerLoop(sink: AudioSink) {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: BlockRing.maxFrames * 2)
        var expectedNext: Double?            // host seconds where the next block should start
        var wasPaused = false
        let rate = sampleRate

        func write(_ p: UnsafePointer<Float>, _ frames: Int) {
            guard sinkError == nil else { return }
            do { try sink.append(p, frames: frames) } catch { sinkError = error; writeFailedFlag.store(true, ordering: .releasing) }
            framesWritten.wrappingAdd(frames, ordering: .relaxed)
        }
        func pad(seconds: Double) {
            var remaining = Int((seconds * rate).rounded())
            while remaining > 0 {
                let n = min(remaining, BlockRing.maxFrames)
                silence.withUnsafeBufferPointer { write($0.baseAddress!, n) }
                remaining -= n
            }
        }

        while true {
            var drained = false
            while ring.read({ p, frames, host in
                let start = Self.seconds(host)
                // A real gap (HAL hiccup, tap rebuild) becomes silence, so the file stays on wall-clock time.
                if let expected = expectedNext, start - expected > 0.02 { pad(seconds: min(start - expected, 30)) }
                expectedNext = start + Double(frames) / rate
                write(p, frames)
                if let bands = analyzer.feed(p, frames: frames) { bandsLock.withLock { $0 = bands } }
            }) { drained = true }

            let isPaused = rt.paused.load(ordering: .acquiring)
            if isPaused { expectedNext = nil; wasPaused = true }
            else if wasPaused { wasPaused = false }
            else if let expected = expectedNext {
                // No callbacks at all for a while: keep time with silence, but stay behind "now" so late blocks still fit.
                let now = Self.seconds(mach_absolute_time())
                if now - expected > 0.35 { pad(seconds: now - 0.25 - expected); expectedNext = now - 0.25 }
            }
            if !running.load(ordering: .acquiring) && !drained { break }
            if !drained { usleep(5_000) }
        }
        do { try sink.finish() } catch { if sinkError == nil { sinkError = error } }
        finished.signal()
    }

    /// The same loop with the voice blended in. Each recorded block waits (at most 250 ms) until the
    /// mic has delivered the same moment, then the mixer adds it. Time-keeping is unchanged.
    private func writerLoopWithVoice(sink: AudioSink) {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        let mixer = VoiceMixer(rate: sampleRate)
        let silence = [Float](repeating: 0, count: BlockRing.maxFrames * 2)
        var pending: [(samples: [Float], frames: Int, start: Double)] = []
        var expectedNext: Double?
        var wasPaused = false
        let rate = sampleRate

        func write(_ p: UnsafePointer<Float>, _ frames: Int) {
            guard sinkError == nil else { return }
            do { try sink.append(p, frames: frames) } catch { sinkError = error; writeFailedFlag.store(true, ordering: .releasing) }
            framesWritten.wrappingAdd(frames, ordering: .relaxed)
        }
        func pad(seconds: Double) {
            var remaining = Int((seconds * rate).rounded())
            while remaining > 0 {
                let n = min(remaining, BlockRing.maxFrames)
                silence.withUnsafeBufferPointer { write($0.baseAddress!, n) }
                remaining -= n
            }
        }
        func emit(_ block: inout (samples: [Float], frames: Int, start: Double)) {
            if let expected = expectedNext, block.start - expected > 0.02 { pad(seconds: min(block.start - expected, 30)) }
            expectedNext = block.start + Double(block.frames) / rate
            let frames = block.frames, start = block.start, cut = voiceCutFlag.load(ordering: .relaxed)
            let gain = Float(bitPattern: UInt32(truncatingIfNeeded: voiceGainBits.load(ordering: .relaxed)))
            let peak = block.samples.withUnsafeMutableBufferPointer { mixer.mix($0.baseAddress!, frames: frames, hostStart: start, cut: cut, gain: gain) }
            voiceMeter.report(peak)
            echoFlag.store(mixer.echo, ordering: .relaxed)
            block.samples.withUnsafeBufferPointer { p in
                write(p.baseAddress!, frames)
                if let bands = analyzer.feed(p.baseAddress!, frames: frames) { bandsLock.withLock { $0 = bands } }
            }
        }

        while true {
            mixer.use(voiceSlot.withLock { $0 })
            mixer.ingest()
            var drained = false
            while ring.read({ p, frames, host in
                pending.append((Array(UnsafeBufferPointer(start: p, count: frames * 2)), frames, Self.seconds(host)))
            }) { drained = true }
            mixer.ingest()
            let now = Self.seconds(mach_absolute_time())
            while var first = pending.first {
                let end = first.start + Double(first.frames) / rate
                guard !mixer.active || mixer.covers(end) || now - end > 0.25 || !running.load(ordering: .acquiring) else { break }
                pending.removeFirst()
                emit(&first)
            }

            let isPaused = rt.paused.load(ordering: .acquiring)
            if isPaused { expectedNext = nil; wasPaused = true }
            else if wasPaused { wasPaused = false }
            else if let expected = expectedNext, pending.isEmpty {
                if now - expected > 0.35 { pad(seconds: now - 0.25 - expected); expectedNext = now - 0.25 }
            }
            if !running.load(ordering: .acquiring) && !drained && pending.isEmpty { break }
            if !drained { usleep(5_000) }
        }
        do { try sink.finish() } catch { if sinkError == nil { sinkError = error } }
        finished.signal()
    }
}
