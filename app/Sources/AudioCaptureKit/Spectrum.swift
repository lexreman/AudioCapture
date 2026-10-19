import Accelerate

/// 28 log-spaced bands from 30 Hz to 16 kHz, 0...1 on a −72...0 dBFS scale.
/// Runs on the writer thread, never on the audio thread.
public final class SpectrumAnalyzer {
    public static let bandCount = 28
    private let n = 2048
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var history: [Float]
    private var filled = 0
    private var sinceLast = 0
    private let hop: Int
    private var real: [Float], imag: [Float], mags: [Float]
    private let edges: [Int]

    public init(sampleRate: Double) {
        log2n = vDSP_Length(log2(Double(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        history = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2); imag = real; mags = real
        hop = Int(sampleRate / 40)                                   // ~40 analyses per second
        let size = n, binHz = sampleRate / Double(size)
        edges = (0...Self.bandCount).map { i in
            let f = 30 * pow(16_000.0 / 30, Double(i) / Double(Self.bandCount))
            return min(size / 2 - 1, max(1, Int((f / binHz).rounded())))
        }
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// Feeds interleaved stereo; returns fresh bands when a new analysis is ready.
    public func feed(_ interleaved: UnsafePointer<Float>, frames: Int) -> [Float]? {
        for f in 0..<frames {
            history[filled % n] = 0.5 * (interleaved[2 * f] + interleaved[2 * f + 1])
            filled += 1
        }
        sinceLast += frames
        guard filled >= n, sinceLast >= hop else { return nil }
        sinceLast = 0
        var frame = [Float](repeating: 0, count: n)
        let start = filled % n
        for i in 0..<n { frame[i] = history[(start + i) % n] * window[i] }
        return frame.withUnsafeBufferPointer { src -> [Float] in
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    mags.withUnsafeMutableBufferPointer { m in
                        vDSP_zvabs(&split, 1, m.baseAddress!, 1, vDSP_Length(n / 2))
                    }
                }
            }
            let norm = Float(n) / 4                              // Hann-window gain for a full-scale sine
            return (0..<Self.bandCount).map { b in
                var peak: Float = 0
                for k in edges[b]...max(edges[b], edges[b + 1] - 1) { peak = max(peak, mags[k]) }
                let db = 20 * log10(max(peak / norm, 1e-6))
                return min(1, max(0, (db + 72) / 72))
            }
        }
    }
}
