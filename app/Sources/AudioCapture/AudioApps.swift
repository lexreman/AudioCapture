import AppKit
import AudioCaptureKit
import CoreAudio
import Observation

/// A user-facing app and every audio process macOS holds it responsible for
/// (Safari's WebKit GPU process, Chrome and Electron helpers, …).
struct AudioApp: Identifiable, Equatable {
    let id: String              // bundle identifier
    var name: String            // CFBundleName: Apple caps it at 15 characters, so it never truncates
    var icon: NSImage
    var processes: [AudioObjectID]
    var runningOutput: Bool
    var isRunning: Bool
    static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.id == b.id && a.name == b.name && a.processes == b.processes && a.runningOutput == b.runningOutput && a.isRunning == b.isRunning
    }
}

/// Peak of one app's audio, measured with its own private mono tap.
/// Runs only while the window is on screen, so the "playing" marks follow real sound,
/// not the app's "audio running" flag (Safari holds that flag while silent).
final class LevelTap {
    private let device: TapDevice
    let meter = PeakMeter()
    private let heartbeat = Heartbeat()
    private let started = mach_absolute_time()
    private(set) var processes: [AudioObjectID]

    /// A tap's aggregate calls back continuously, silence included. No callback for this long means
    /// the system dropped it (device switch, a call starting, coreaudiod restart): it must be rebuilt.
    var stalled: Bool { heartbeat.silence(since: started) > 1.5 }

    init?(processes: [AudioObjectID]) {
        guard let device = TapDevice(description: CATapDescription(monoMixdownOfProcesses: processes), name: "Audio Capture level") else { return nil }
        self.device = device; self.processes = processes
        let meter = meter, heartbeat = heartbeat
        guard device.start({ _, input, _, _, _ in
            heartbeat.beat()
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var peak: Float = 0
            for buffer in abl {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(buffer.mDataByteSize) / 4 { peak = max(peak, abs(data[i])) }
            }
            meter.report(peak)
        }) else { return nil }
    }

    func update(processes: [AudioObjectID]) {
        guard processes != self.processes else { return }
        self.processes = processes
        device.setProcesses(processes)
    }
}

@MainActor @Observable
final class AudioApps {
    private(set) var apps: [String: AudioApp] = [:]
    /// Apps making sound right now, and apps that made sound in the last 60 s.
    /// Published only when membership changes, never at meter rate.
    private(set) var sounding: Set<String> = []
    private(set) var recent: Set<String> = []
    /// True once any tap has delivered real (non-zero) audio: proof of access, whatever TCC's preflight says.
    private(set) var heardAudio = false
    @ObservationIgnored private var soundTimes: [String: Date] = [:]
    @ObservationIgnored private(set) var soundStarted: [String: Date] = [:]
    /// Smoothed level per app, read by the marks at display rate (not observed).
    @ObservationIgnored private(set) var levels: [String: Float] = [:]
    @ObservationIgnored private var taps: [String: LevelTap] = [:]
    @ObservationIgnored private var listeners: [HAL.Listener] = []
    @ObservationIgnored private var processListeners: [AudioObjectID: HAL.Listener] = [:]
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var sampleCount = 0
    @ObservationIgnored private var runningApps: NSKeyValueObservation?
    @ObservationIgnored private let ownBundleID = Bundle.main.bundleIdentifier

    /// Level taps run only while this is true (window visible, permission granted).
    var metering = false { didSet { if metering != oldValue { syncTaps(); updatePoll() } } }

    init() {
        listeners.append(HAL.Listener(HAL.system, kAudioHardwarePropertyProcessObjectList, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // Launches and quits, from macOS's own list of running apps: it changes for every app, while the
        // "did terminate" notice never comes for some (Messages, Podcasts), which then stayed listed.
        runningApps = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Levels are read 30 times a second only while they are shown: with the window hidden, nothing ticks.
    private func updatePoll() {
        if metering {
            guard poll == nil else { return }
            poll = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleLevels() }
            }
        } else {
            poll?.invalidate(); poll = nil
            // Nothing is measured while hidden: no level or "playing" mark is left standing, as before.
            levels = [:]
            if !sounding.isEmpty { sounding = [] }
        }
    }

    func isSounding(_ id: String) -> Bool { sounding.contains(id) }
    func lastSoundTime(_ id: String) -> Date? { soundTimes[id] }

    func processes(for id: String) -> [AudioObjectID] { apps[id]?.processes ?? [] }
    func isOpen(_ id: String) -> Bool {
        if staged { return apps[id]?.isRunning ?? false }
        return Self.running(id)
    }

    /// Open: a copy of the app runs that macOS hasn't marked as quit.
    private static func running(_ id: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
    }
    var debugTaps: String { taps.keys.sorted().joined(separator: ",") + " levels=" + levels.map { "\($0.key)=\(String(format: "%.4f", $0.value))" }.sorted().joined(separator: ",") }

    /// Development renders only: a fixed set of apps, shown open, with fixed levels; live updates stop.
    @ObservationIgnored private var staged = false
    func _debugStage(_ ids: [String], playing: [String: Float]) {
        staged = true
        apps = [:]
        for id in ids { remember(bundleID: id); apps[id]?.isRunning = true }
        let now = Date()
        for (i, id) in playing.keys.sorted().enumerated() { soundStarted[id] = now.addingTimeInterval(Double(-60 + i)); soundTimes[id] = now }
        sounding = Set(playing.keys); recent = Set(playing.keys); levels = playing
    }

    /// Development renders only: a staged app shown closed.
    func _debugClose(_ id: String) { apps[id]?.isRunning = false }

    func refresh() {
        if staged { return }
        var groups: [String: AudioApp] = [:]
        var seen = Set<AudioObjectID>()
        for obj in HAL.processObjects() {
            seen.insert(obj)
            if processListeners[obj] == nil {
                processListeners[obj] = HAL.Listener(obj, kAudioProcessPropertyIsRunningOutput, queue: .main) { [weak self] in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
            let pid = HAL.pid(of: obj)
            guard pid > 0, let app = NSRunningApplication(processIdentifier: HAL.responsiblePID(pid)),
                  app.activationPolicy == .regular, let bundleID = app.bundleIdentifier, bundleID != ownBundleID else { continue }
            var entry = groups[bundleID] ?? AudioApp(id: bundleID, name: Self.shortName(app), icon: app.icon ?? NSImage(),
                                                     processes: [], runningOutput: false, isRunning: !app.isTerminated)
            entry.processes.append(obj)
            entry.runningOutput = entry.runningOutput || HAL.isRunningOutput(obj)
            groups[bundleID] = entry
        }
        processListeners = processListeners.filter { seen.contains($0.key) }
        // Apps we knew that have no audio process now keep their identity (closed or quiet rows).
        for (id, old) in apps where groups[id] == nil {
            var kept = old
            kept.processes = []; kept.runningOutput = false
            kept.isRunning = Self.running(id)
            groups[id] = kept
        }
        if groups != apps { apps = groups }
        syncTaps()
    }

    /// Keeps a remembered app known even before it plays (for the restored selection).
    func remember(bundleID: String) {
        guard apps[bundleID] == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        apps[bundleID] = AudioApp(id: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), processes: [],
                                  runningOutput: false, isRunning: Self.running(bundleID))
    }

    private static func shortName(_ app: NSRunningApplication) -> String {
        if let url = app.bundleURL, let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty { return name }
        return app.localizedName ?? "App"
    }

    private func syncTaps() {
        guard metering else { taps.removeAll(); return }
        for (id, app) in apps {
            let wanted = app.runningOutput && !app.processes.isEmpty
            if wanted {
                if let tap = taps[id] { tap.update(processes: app.processes) } else { taps[id] = LevelTap(processes: app.processes) }
            } else {
                taps[id] = nil
            }
        }
        for id in taps.keys where apps[id] == nil { taps[id] = nil }
    }

    private func sampleLevels() {
        if staged { return }
        let now = Date()
        // Every 2 s: rebuild level taps the system dropped, and retry ones that failed to start.
        sampleCount &+= 1
        if metering && sampleCount % 60 == 0 {
            for (id, tap) in taps where tap.stalled { taps[id] = nil }
            syncTaps()
        }
        for (id, tap) in taps { record(id, tap.meter.take(), now) }
        for id in levels.keys where taps[id] == nil { levels[id] = max(0, (levels[id] ?? 0) * 0.82) }
        let nowSounding = Set(soundTimes.filter { now.timeIntervalSince($0.value) < 0.4 }.keys)
        let nowRecent = Set(soundTimes.filter { now.timeIntervalSince($0.value) < 60 }.keys)
        for id in nowSounding.subtracting(sounding) { soundStarted[id] = now }
        if nowSounding != sounding { sounding = nowSounding }
        if nowRecent != recent { recent = nowRecent }
    }

    /// −60 dBFS is the threshold for "making sound".
    private func record(_ id: String, _ peak: Float, _ now: Date) {
        levels[id] = max(peak, (levels[id] ?? 0) * 0.82)
        if peak > 0.001 { soundTimes[id] = now }
        if peak > 0, !heardAudio { heardAudio = true }
    }
}
