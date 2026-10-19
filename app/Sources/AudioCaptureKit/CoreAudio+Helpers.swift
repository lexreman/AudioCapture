import AppKit
import CoreAudio

/// Thin, typed access to the Core Audio HAL property API.
public enum HAL {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func address(_ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    public static func u32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = address(selector); var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    public static func f64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var a = address(selector); var v: Float64 = 0; var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    public static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector); var v: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v?.takeRetainedValue() as String?
    }

    public static func objects(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(selector); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    // MARK: Processes

    public static func processObjects() -> [AudioObjectID] { objects(system, kAudioHardwarePropertyProcessObjectList) }

    /// The microphones a process is reading from right now (empty when it isn't).
    public static func inputDevices(of process: AudioObjectID) -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var n: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &a, 0, nil, &n) == noErr, n > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(n) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(process, &a, 0, nil, &n, &out) == noErr else { return [] }
        return out
    }
    public static func isRunningInput(_ process: AudioObjectID) -> Bool { u32(process, kAudioProcessPropertyIsRunningInput) == 1 }
    public static var defaultInputDevice: AudioObjectID? { objects(system, kAudioHardwarePropertyDefaultInputDevice).first.flatMap { $0 == 0 ? nil : $0 } }

    public static func processObject(pid: pid_t) -> AudioObjectID {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var p = pid; var obj: AudioObjectID = 0; var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
        return obj
    }

    public static func pid(of process: AudioObjectID) -> pid_t {
        var a = address(kAudioProcessPropertyPID); var p: pid_t = -1; var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &a, 0, nil, &size, &p)
        return p
    }

    public static func isRunningOutput(_ process: AudioObjectID) -> Bool { u32(process, kAudioProcessPropertyIsRunningOutput) == 1 }

    /// The process macOS holds responsible for `pid`: a browser's audio helper resolves to the browser.
    public static func responsiblePID(_ pid: pid_t) -> pid_t { Responsibility.lookup?(pid) ?? pid }

    // MARK: Listeners

    public final class Listener: @unchecked Sendable {
        let object: AudioObjectID; var address: AudioObjectPropertyAddress; let block: AudioObjectPropertyListenerBlock; let queue: DispatchQueue
        public init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) {
            self.object = object; self.address = HAL.address(selector); self.queue = queue
            self.block = { _, _ in handler() }
            AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        }
        deinit { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
    }
}

/// `responsibility_get_pid_responsible_for_pid` is private; resolved once, optional at runtime.
enum Responsibility {
    typealias Fn = @convention(c) (pid_t) -> pid_t
    static let lookup: Fn? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Fn.self) }
}

// MARK: - Taps and the device-free aggregate

/// A process tap wrapped in a private aggregate that contains *only* the tap.
/// No output device is part of it, so speaker changes, device sample rate and
/// system volume never reach the capture (measured).
public final class TapDevice: @unchecked Sendable {
    public private(set) var tap: AudioObjectID = 0
    public private(set) var aggregate: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    public private(set) var sampleRate: Double = 48_000
    public private(set) var channels: Int = 2

    public init?(description: CATapDescription, name: String) {
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        let tapUID = HAL.string(tap, kAudioTapPropertyUID) ?? description.uuid.uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate) == noErr else {
            AudioHardwareDestroyProcessTap(tap); tap = 0; return nil
        }
        var fmtAddr = HAL.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &size, &asbd) == noErr, asbd.mChannelsPerFrame > 0 {
            channels = Int(asbd.mChannelsPerFrame)
        }
        // The aggregate's clock is the truth for the delivered rate (tap format can disagree on device-bound aggregates).
        sampleRate = HAL.f64(aggregate, kAudioDevicePropertyNominalSampleRate) ?? asbd.mSampleRate
    }

    /// Starts IO. `body` runs on the HAL real-time thread: copy, measure, return. Nothing else.
    @discardableResult
    public func start(_ body: @escaping AudioDeviceIOBlock) -> Bool {
        guard procID == nil else { return true }
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil, body) == noErr, let procID else { return false }
        return AudioDeviceStart(aggregate, procID) == noErr
    }

    public func setProcesses(_ processes: [AudioObjectID]) {
        var a = HAL.address(kAudioTapPropertyDescription)
        var ref: Unmanaged<CATapDescription>?; var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        guard AudioObjectGetPropertyData(tap, &a, 0, nil, &size, &ref) == noErr, let desc = ref?.takeRetainedValue() else { return }
        guard Set(desc.processes) != Set(processes) else { return }
        desc.processes = processes
        var value: CATapDescription = desc
        _ = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(tap, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
    }

    public func stop() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
            self.procID = nil
        }
    }

    deinit {
        stop()
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
    }
}

// MARK: - Permission

/// System Audio Recording permission. There is no public preflight; TCC's SPI is the reliable read.
public enum AudioCapturePermission {
    public enum Status: Sendable { case granted, denied, undetermined }
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    public static var status: Status {
        guard let sym = dlsym(tcc, "TCCAccessPreflight") else { return .undetermined }
        switch unsafeBitCast(sym, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    public static func request(_ done: @escaping @Sendable (Bool) -> Void) {
        guard let sym = dlsym(tcc, "TCCAccessRequest") else { done(false); return }
        unsafeBitCast(sym, to: Request.self)(service, nil) { granted in done(granted) }
    }

    public static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
}
