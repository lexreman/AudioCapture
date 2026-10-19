@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia

/// Ordered by fidelity and size: compressed → lossless → raw.
public enum CaptureFormat: String, CaseIterable, Sendable, Codable {
    case aac, lossless, wav
    public var fileExtension: String { self == .wav ? "wav" : "m4a" }
    public var title: String {
        switch self {
        case .lossless: "Lossless"
        case .aac: "AAC"
        case .wav: "WAV"
        }
    }
}

/// Destination for interleaved stereo Float32 frames. Written only from the writer thread.
protocol AudioSink: AnyObject {
    func append(_ interleaved: UnsafePointer<Float>, frames: Int) throws
    func finish() throws
}

enum SinkError: Error { case setup(String), write(String) }

func makeSink(format: CaptureFormat, url: URL, sampleRate: Double) throws -> AudioSink {
    switch format {
    case .lossless, .aac: return try M4ASink(url: url, sampleRate: sampleRate, aac: format == .aac)
    case .wav: return try WAVSink(url: url, sampleRate: sampleRate)
    }
}

/// .m4a through AVAssetWriter with 1 s movie fragments: a crash or power loss
/// leaves a file that plays up to the last second (measured: 118 of 120 s at 2 s fragments).
final class M4ASink: AudioSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private let sampleRate: Double
    private var written: Int64 = 0

    init(url: URL, sampleRate: Double, aac: Bool) throws {
        self.sampleRate = sampleRate
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2]
        if aac {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 256_000
        } else {
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 24
        }
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw SinkError.setup("input") }
        writer.add(input)
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        guard let desc, writer.startWriting() else { throw SinkError.setup(writer.error?.localizedDescription ?? "start") }
        format = desc
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ interleaved: UnsafePointer<Float>, frames: Int) throws {
        guard frames > 0 else { return }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: interleaved, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { throw SinkError.write("block") }
        var sample: CMSampleBuffer?
        let pts = CMTime(value: written, timescale: CMTimeScale(sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                   sampleCount: frames, presentationTimeStamp: pts,
                                                                   packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample else { throw SinkError.write("sample") }
        var waited = 0
        while !input.isReadyForMoreMediaData && waited < 2000 { usleep(1000); waited += 1 }
        guard input.append(sample) else { throw SinkError.write(writer.error?.localizedDescription ?? "append") }
        written += Int64(frames)
    }

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw SinkError.write(writer.error?.localizedDescription ?? "finish") }
    }
}

/// WAV as RF64 (no 4 GiB ceiling) with size fields kept current, so a killed recording stays readable.
final class WAVSink: AudioSink {
    private var file: ExtAudioFileRef?

    init(url: URL, sampleRate: Double) throws {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var ref: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileRF64Type, &asbd, nil, AudioFileFlags.eraseFile.rawValue, &ref) == noErr,
              let ref else { throw SinkError.setup("wav") }
        ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbd)
        var audioFile: AudioFileID?; var size = UInt32(MemoryLayout<AudioFileID?>.size)
        if ExtAudioFileGetProperty(ref, kExtAudioFileProperty_AudioFile, &size, &audioFile) == noErr, let audioFile {
            var defer0: UInt32 = 0
            AudioFileSetProperty(audioFile, kAudioFilePropertyDeferSizeUpdates, 4, &defer0)
        }
        file = ref
    }

    func append(_ interleaved: UnsafePointer<Float>, frames: Int) throws {
        guard let file, frames > 0 else { return }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8),
                                                                            mData: UnsafeMutableRawPointer(mutating: interleaved)))
        guard ExtAudioFileWrite(file, UInt32(frames), &list) == noErr else { throw SinkError.write("wav") }
    }

    func finish() throws {
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }
}
