import CoreAudio
import Darwin

/// Lock-free single-producer / single-consumer ring of audio blocks.
/// The producer is the HAL real-time thread: it only copies into preallocated
/// memory and publishes an index. No locks, no allocation, no Swift runtime calls.
public final class BlockRing: @unchecked Sendable {
    public static let maxFrames = 4096
    public let capacity: Int
    private let samples: UnsafeMutablePointer<Float>     // capacity × maxFrames × 2, interleaved stereo
    private let frameCounts: UnsafeMutablePointer<Int>
    private let hostTimes: UnsafeMutablePointer<UInt64>
    private let head = Atomic<Int>(0)                    // next slot the producer writes
    private let tail = Atomic<Int>(0)                    // next slot the consumer reads

    public init(seconds: Double = 12, sampleRate: Double = 48_000) {
        let blocks = max(64, Int((seconds * sampleRate) / 512))
        capacity = blocks
        samples = .allocate(capacity: blocks * Self.maxFrames * 2)
        frameCounts = .allocate(capacity: blocks)
        hostTimes = .allocate(capacity: blocks)
    }
    deinit { samples.deallocate(); frameCounts.deallocate(); hostTimes.deallocate() }

    // MARK: Producer (real-time thread)

    /// Copies one IO buffer list as interleaved stereo. Returns the block's peak.
    @inline(__always)
    public func write(_ list: UnsafePointer<AudioBufferList>, hostTime: UInt64) -> Float {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = abl.first, let firstData = first.mData else { return 0 }
        let h = head.load(ordering: .relaxed), t = tail.load(ordering: .acquiring)
        if h - t >= capacity { return 0 }                // full: the block is dropped, the writer pads the gap
        let slot = h % capacity
        let dst = samples + slot * Self.maxFrames * 2
        var peak: Float = 0
        var frames = 0
        if abl.count == 1 {
            let ch = max(1, Int(first.mNumberChannels))
            frames = min(Self.maxFrames, Int(first.mDataByteSize) / (4 * ch))
            let src = firstData.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                let l = src[f * ch], r = ch > 1 ? src[f * ch + 1] : l
                dst[2 * f] = l; dst[2 * f + 1] = r
                peak = max(peak, abs(l), abs(r))
            }
        } else {
            frames = min(Self.maxFrames, Int(first.mDataByteSize) / 4)
            let l = firstData.assumingMemoryBound(to: Float.self)
            let r = abl[1].mData?.assumingMemoryBound(to: Float.self) ?? l
            for f in 0..<frames {
                dst[2 * f] = l[f]; dst[2 * f + 1] = r[f]
                peak = max(peak, abs(l[f]), abs(r[f]))
            }
        }
        frameCounts[slot] = frames
        hostTimes[slot] = hostTime
        head.store(h + 1, ordering: .releasing)
        return peak
    }

    // MARK: Consumer

    /// Hands the oldest block to `body` (interleaved stereo pointer, frame count, host time). Returns false when empty.
    @discardableResult
    public func read(_ body: (UnsafePointer<Float>, Int, UInt64) -> Void) -> Bool {
        let t = tail.load(ordering: .relaxed), h = head.load(ordering: .acquiring)
        guard t < h else { return false }
        let slot = t % capacity
        body(samples + slot * Self.maxFrames * 2, frameCounts[slot], hostTimes[slot])
        tail.store(t + 1, ordering: .releasing)
        return true
    }
}

/// Peak-since-last-read, written from the real-time thread.
public final class PeakMeter: @unchecked Sendable {
    private let bits = Atomic<UInt32>(0)
    public init() {}
    @inline(__always) public func report(_ peak: Float) {
        var current = bits.load(ordering: .relaxed)
        while peak > Float(bitPattern: current) {
            let (exchanged, original) = bits.compareExchange(expected: current, desired: peak.bitPattern, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }
    public func take() -> Float { Float(bitPattern: bits.exchange(0, ordering: .relaxed)) }
}

/// Host time of the last real-time callback, so the main thread can tell a running tap from a stalled one.
public final class Heartbeat: @unchecked Sendable {
    private let last = Atomic<UInt64>(0)
    public init() {}
    @inline(__always) public func beat() { last.store(mach_absolute_time(), ordering: .relaxed) }
    /// Seconds since the last callback (or since `start` if none came yet).
    public func silence(since start: UInt64) -> Double {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let ref = max(last.load(ordering: .relaxed), start)
        return Double(mach_absolute_time() &- ref) * Double(tb.numer) / Double(tb.denom) / 1e9
    }
}
