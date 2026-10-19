import AppKit
import AudioCaptureKit
import AVFoundation
import CoreAudio
import Observation
import Security
import SwiftUI

enum Selection: Equatable, Hashable {
    case everything
    case apps([String])            // one or more apps, in the order they were chosen
    static func app(_ id: String) -> Selection { .apps([id]) }
    var appIDs: [String] { if case .apps(let ids) = self { ids } else { [] } }
    var appID: String? { appIDs.first }
    func contains(_ id: String) -> Bool { appIDs.contains(id) }
}

enum Phase: Equatable {
    case onboarding
    case ready
    case recording
    case paused          // the recorded app quit: frozen, waiting for the person
    case finished        // chip showing the file that was just written
}

@MainActor @Observable
final class AppModel {
    // MARK: State the window shows
    var phase: Phase = .ready
    var selection: Selection = .everything { didSet { persistSelection() } }
    private(set) var elapsed: Double = 0
    private(set) var bytes: Int64 = 0
    private(set) var chip: Capture?
    private(set) var noAccess = false
    /// The last recording's file couldn't be put in its folder (the folder's drive was unplugged).
    private(set) var saveFailed = false
    private(set) var permission: AudioCapturePermission.Status = AudioCapturePermission.status
    private var accessConfirmed = false
    /// What Settings shows: TCC's preflight can say "undetermined" for an allowed app, so real evidence wins.
    var accessAllowed: Bool { permission == .granted || apps.heardAudio || (accessConfirmed && permission != .denied) }
    private(set) var targetReopened = false
    var pinned: Bool = prefs.bool(forKey: "pinned") { didSet { prefs.set(pinned, forKey: "pinned"); onPinned?(pinned) } }
    var innerRadius: CGFloat = 10
    var listHovered = false { didSet { if listHovered && !oldValue { frozenOrder = rankedAppIDs } } }
    var chipHovered = false
    /// How many app rows the list shows: 3 at least, more when the person drags the window taller (remembered).
    /// The microphone in recordings, in dB from −12 to +12 (0: as recorded). Only the file changes,
    /// never the mic itself or what other apps receive.
    var micLevel: Double = min(12, max(-12, prefs.double(forKey: "micLevel"))) {
        didSet { prefs.set(micLevel, forKey: "micLevel"); recorder?.setVoiceLevel(decibels: Float(micLevel)) }
    }
    var listRows: Int = max(3, prefs.integer(forKey: "listRows")) {
        didSet { prefs.set(listRows, forKey: "listRows") }
    }
    /// False until macOS reports the window on screen: an app launched hidden never meters.
    var windowVisible = false { didSet { updateMetering() } }
    /// System Settings › Accessibility › Display › Increase Contrast: tiles gain an edge, dimmed rows stay readable.
    var increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    /// Rows that can't be picked while recording: dimmed, still readable. Measured on renders: text
    /// against its tile at about 3 : 1 (light needs more opacity: its grey text starts paler).
    func lockedOpacity(dark: Bool) -> Double {
        switch (dark, increasedContrast) {
        case (true, false): 0.6
        case (true, true): 0.8
        case (false, false): 0.85
        case (false, true): 0.92
        }
    }

    // MARK: Your voice ("Include my voice", per source, remembered)
    private(set) var voiceApps = Set(prefs.stringArray(forKey: "voiceApps") ?? [])
    private(set) var voiceEverything = prefs.bool(forKey: "voiceEverything")
    /// While recording: the voice is part of this recording, the mic is live right now, the mic hears the call.
    private(set) var voiceInRecording = false
    private(set) var voiceLive = false
    private(set) var echoWarning = false
    /// While recording: nothing heard from the source for a while (shown, and cleared, as it happens).
    enum Silence: Equatable { case notYet, aMinute }
    private(set) var silence: Silence?
    var voiceCut = false { didSet { recorder?.voiceCut = voiceCut } }

    // MARK: Settings
    var folder: URL { didSet { prefs.set(folder.path, forKey: "folder") } }
    var format: CaptureFormat { didSet { prefs.set(format.rawValue, forKey: "format") } }

    let apps = AudioApps()

    // MARK: Hooks for the shell (Dock, window)
    @ObservationIgnored var onRecordingChanged: ((Bool) -> Void)?
    @ObservationIgnored var onTick: ((Double) -> Void)?
    @ObservationIgnored var onPinned: ((Bool) -> Void)?

    // MARK: Private
    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var hiddenURL: URL?
    @ObservationIgnored private var finalURL: URL?
    @ObservationIgnored private var target: Selection = .everything
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var settleTimer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var frozenOrder: [String] = []
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var silentRebuilds = 0
    @ObservationIgnored private var stoppedForSleep = false
    static let sleepNote = String(localized: "Saved at sleep")
    /// The file saved when the Mac went to sleep, shown again on wake.
    @ObservationIgnored private var sleepCapture: Capture?
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var recoverAgain = false
    @ObservationIgnored private var failedSave: Pending?        // the recording "couldn't be saved" is about
    @ObservationIgnored private var recoveredWaiting: Capture?  // recovered while busy: shown once the window is free
    @ObservationIgnored private var voiceChoiceWaiting: (@MainActor () -> Void)?   // answered mid-recording: applied after it
    @ObservationIgnored private let ownProcess = HAL.processObject(pid: getpid())

    init() {
        let d = prefs
        // New here: Music › Audio Capture, made only when the first recording is saved (nothing is left
        // behind for someone who never records), and outside the folders macOS asks permission for.
        folder = d.string(forKey: "folder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Audio Capture")
        format = d.string(forKey: "format").flatMap(CaptureFormat.init(rawValue:)) ?? .aac
        if let ids = d.stringArray(forKey: "lastSources"), !ids.isEmpty {
            selection = .apps(ids); ids.forEach { apps.remember(bundleID: $0) }
        } else if let id = d.string(forKey: "lastSource") { selection = .app(id); apps.remember(bundleID: id) }

        let status = AudioCapturePermission.status
        noAccess = status == .denied
        // TCC's preflight can report "undetermined" for an app that is in fact allowed, so it never gates
        // anything on its own: the one-sentence screen shows on a genuine first run only.
        phase = (status == .undetermined && !d.bool(forKey: "onboarded")) ? .onboarding : .ready

        recoverInterrupted()
        primeFolderAccess()
        // An ad hoc signature (every download, and builds without a certificate) changes with each version,
        // and macOS then keeps a microphone grant that no longer matches: Include my voice would record
        // silence. A new signature resets that grant and the voice choices, so the next voice recording asks
        // again, cleanly. Only this app's own grant is touched.
        // A launch whose signature differs from the last one counts, whatever the voice choices are now (a
        // grant left from a voice turned off earlier is just as stale); a build signed by a team is noted too.
        if !testRun, Bundle.main.bundleIdentifier != nil, let signature = CodeSignature.current {
            let mark = signature.team.map { "team:" + $0 } ?? signature.cdhash
            let last = d.string(forKey: "signature")
            // Ad hoc: any change, or no record yet. Team-signed: a change from an earlier mark (an ad hoc build
            // before it, or another certificate); a first team-signed launch has no stale grant to fix.
            let changed = signature.team == nil ? last != mark : (last != nil && last != mark)
            if changed, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                CodeSignature.resetMicrophoneGrant()
                voiceApps = []; voiceEverything = false
                prefs.set([String](), forKey: "voiceApps"); prefs.set(false, forKey: "voiceEverything")
            }
            prefs.set(mark, forKey: "signature")
        }
        // Your voice choices only stand while macOS still grants the mic: without the grant they reset too,
        // and right-clicking again makes macOS ask again.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized, !voiceApps.isEmpty || voiceEverything {
            voiceApps = []; voiceEverything = false
            prefs.set([String](), forKey: "voiceApps"); prefs.set(false, forKey: "voiceEverything")
        }
        updateMetering()        // listen from launch, not only once the app is first activated
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckAccess() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
        }
        // Closing the lid sleeps the Mac whatever an app asks, and audio stops with it: save the file
        // cleanly before sleep, and show it again on wake so the reason is seen.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recorder != nil else { return }
                self.stoppedForSleep = true
                self.stop(note: Self.sleepNote)
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.stoppedForSleep else { return }
                self.stoppedForSleep = false
                if let capture = self.sleepCapture { self.sleepCapture = nil; self.show(capture) }
            }
        }
        // A drive comes back: publish any recording that couldn't be saved on it.
        ws.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverPending() }
        }
    }

    // MARK: The list

    /// Every app that uses audio, so a source can be picked before it plays. Order: playing now
    /// (in the order they started), then played in the last 60 s (most recent first), then the rest
    /// by name. The order holds still while the pointer is over the list.
    var visibleAppIDs: [String] {
        var ids = Set(apps.apps.values.filter { !$0.processes.isEmpty || $0.isRunning }.map(\.id))
        ids.formUnion(selection.appIDs)
        if isLive { ids.formUnion(target.appIDs) }
        let present = ids.filter { apps.apps[$0] != nil }
        if listHovered {
            let kept = frozenOrder.filter(present.contains)
            return kept + present.subtracting(kept).sorted { name($0) < name($1) }
        }
        return ranked(present)
    }

    /// The live order, ignoring hover (what the list freezes when the pointer enters it).
    private var rankedAppIDs: [String] {
        var ids = Set(apps.apps.values.filter { !$0.processes.isEmpty || $0.isRunning }.map(\.id))
        ids.formUnion(selection.appIDs)
        if isLive { ids.formUnion(target.appIDs) }
        return ranked(ids.filter { apps.apps[$0] != nil })
    }

    private func ranked(_ present: Set<String>) -> [String] {
        // One ranking whatever the window or permission state, so rows never jump when the window
        // comes forward: playing now, played in the last 60 s, audio open (a paused tab), the rest.
        func rank(_ id: String) -> Int {
            if apps.sounding.contains(id) { return 0 }
            if apps.recent.contains(id) { return 1 }
            if apps.apps[id]?.runningOutput == true { return 2 }
            return 3
        }
        return present.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if ra == 0 { return (apps.soundStarted[a] ?? .distantPast) < (apps.soundStarted[b] ?? .distantPast) }
            if ra == 1 { return (apps.lastSoundTime(a) ?? .distantPast) > (apps.lastSoundTime(b) ?? .distantPast) }
            return name(a).localizedStandardCompare(name(b)) == .orderedAscending
        }
    }
    private func name(_ id: String) -> String { apps.apps[id]?.name ?? id }

    var isLive: Bool { phase == .recording || phase == .paused }
    var selectionName: String { Self.names(selection.appIDs.map(appName)) ?? String(localized: "Everything") }
    /// "Record Safari", or "Record Everything" as its own phrase (languages word it differently).
    var recordTitle: String {
        selection.appIDs.isEmpty ? String(localized: "Record Everything") : String(localized: "Record \(selectionName)")
    }
    /// "Safari", "Safari + Music", "Safari + 2 more": short enough to never be cut.
    static func names(_ list: [String]) -> String? {
        switch list.count {
        case 0: nil
        case 1, 2: list.joined(separator: " + ")
        default: String(localized: "\(list[0]) + \(list.count - 1) more")
        }
    }

    /// Click: that app alone. ⌘-click: add or remove it. Shift-click: every app from the last one
    /// clicked to this one (the list holds its order while the pointer is over it).
    @ObservationIgnored private var anchor: String?
    func click(_ id: String, modifiers: NSEvent.ModifierFlags) {
        guard !isLive else { return }
        var ids = selection.appIDs
        if modifiers.contains(.command) {
            if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
            select(ids.isEmpty ? .everything : .apps(ids))
            anchor = id
        } else if modifiers.contains(.shift), let anchor, let a = visibleAppIDs.firstIndex(of: anchor),
                  let b = visibleAppIDs.firstIndex(of: id) {
            select(.apps(Array(visibleAppIDs[min(a, b)...max(a, b)])))
        } else {
            select(.app(id))
            anchor = id
        }
    }

    /// Up and Down arrows: the row above or below, alone. Everything sits above the first app.
    func moveSelection(by step: Int) {
        guard !isLive, !isStarting, phase != .onboarding else { return }
        let ids = visibleAppIDs
        let current: Int
        switch selection {
        case .everything: current = 0
        case .apps(let chosen):
            let from = anchor.flatMap { chosen.contains($0) ? $0 : nil } ?? chosen.last
            current = from.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        }
        let next = min(max(current + step, 0), ids.count)
        let target: Selection = next == 0 ? .everything : .app(ids[next - 1])
        guard target != selection else { return }
        select(target)
        anchor = next == 0 ? nil : ids[next - 1]
    }

    /// The app's short name even if it has dropped out of the audio list (CFBundleName, then Finder's name).
    private func appName(_ id: String) -> String {
        if let name = apps.apps[id]?.name { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        }
        return id
    }
    var folderName: String { Files.displayName(folder) }

    func select(_ s: Selection) {
        guard !isLive, !isStarting else { return }
        if saveFailed { saveFailed = false }
        selection = s
        if phase == .finished { settle() }
    }

    // MARK: Primary action: record / stop / resume

    func primary() {
        switch phase {
        case .onboarding: return
        case .ready, .finished: start()
        case .recording: stop()
        case .paused: resume()
        }
    }

    /// The selected app is not open: nothing to record, the record button is disabled and the bubble says so.
    var selectionUnavailable: Bool { !selection.appIDs.isEmpty && !selection.appIDs.contains(where: apps.isOpen) }

    func voiceIncluded(_ s: Selection) -> Bool {
        if s.appIDs.isEmpty { return voiceEverything }
        return s.appIDs.contains(where: voiceApps.contains)
    }

    /// Turning it on asks macOS for the microphone the first time; refused, it opens the right Settings pane.
    func setVoiceIncluded(_ on: Bool, for s: Selection) {
        guard !isLive, !isStarting else { return }      // the recording being started keeps the choice it began with
        let apply: @MainActor () -> Void = { [self] in
            if let id = s.appID { if on { voiceApps.insert(id) } else { voiceApps.remove(id) } } else { voiceEverything = on }
            prefs.set(Array(voiceApps), forKey: "voiceApps")
            prefs.set(voiceEverything, forKey: "voiceEverything")
        }
        guard on else { apply(); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: apply()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard granted else { return }
                    // Answered after a recording began: that recording keeps its choice; this one waits for it to end.
                    if self.isLive || self.isStarting { self.voiceChoiceWaiting = apply } else { apply() }
                }
            }
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
        }
    }

    /// The mic to follow: the one the recorded app is reading (only while it is), or the system input for Everything.
    private func voiceDevice() -> AudioObjectID? {
        guard !target.appIDs.isEmpty else { return HAL.defaultInputDevice }
        for p in target.appIDs.flatMap(apps.processes(for:)) where HAL.isRunningInput(p) {
            if let d = HAL.inputDevices(of: p).first { return d }
        }
        return nil
    }

    /// Read by the tile's mic at display rate.
    func takeVoiceLevel() -> Float { recorder?.takeVoicePeak() ?? debugVoiceLevel }

    func start() {
        guard !selectionUnavailable, !isStarting, recorder == nil else { return }
        saveFailed = false
        if AudioCapturePermission.status == .denied { noAccess = true; permission = .denied; return }
        if phase == .finished { settle() }
        // "Zen - 14-10-2026, 15.32" for an app, "Audio Capture - …" only for Everything.
        let ids = selection.appIDs
        let base = Files.baseName(source: ids.isEmpty ? "Audio Capture" : ids.map(appName).joined(separator: " + "), date: Date())
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = Files.unique(base, ext: format.fileExtension, in: folder)
        let hidden = Files.hidden(final)
        let source: Recorder.Source
        switch selection {
        case .everything: source = .everything(excluding: ownProcess)
        case .apps(let ids): source = .app(ids.flatMap(apps.processes(for:)))
        }
        let rec = Recorder(source: source, format: format, url: hidden, includesVoice: voiceIncluded(selection))
        rec.setVoiceLevel(decibels: Float(micLevel))
        // Your voice is wanted but macOS hasn't been asked (a new build resets it): ask now; the voice joins once allowed.
        if rec.includesVoice, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        let chosen = selection
        isStarting = true
        // Starting a tap can wait on macOS (e.g. the permission prompt): never on the main thread.
        Task.detached(priority: .userInitiated) {
            let started = (try? rec.start()) != nil
            await MainActor.run {
                self.isStarting = false
                guard started else { NSSound.beep(); self.recheckAccess(); self.applyWaitingVoiceChoice(); return }
                self.recorder = rec; self.hiddenURL = hidden; self.finalURL = final; self.target = chosen
                prefs.set([hidden.path, final.path], forKey: "inProgress")
                prefs.set(Files.bookmark(hidden), forKey: "inProgressBookmark")
                self.sleepCapture = nil
                self.elapsed = 0; self.bytes = 0; self.targetReopened = false
                self.voiceInRecording = rec.includesVoice; self.voiceCut = false; self.voiceLive = false; self.echoWarning = false
                self.silence = nil; self.silentRebuilds = 0
                self.activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording audio")
                self.phase = .recording
                self.startTicker()
                self.onRecordingChanged?(true)
                self.recheckAccess()
            }
        }
    }

    func stop(note: String? = nil) {
        guard let rec = recorder, let hidden = hiddenURL, let final = finalURL else { return }
        let source = target.appID
        let pending = Pending(hidden: hidden.path, final: final.path, bookmark: prefs.data(forKey: "inProgressBookmark"))
        recorder = nil
        // Apps that quit during the recording leave the selection with it (Everything when none is left open).
        let open = selection.appIDs.filter(apps.isOpen)
        if open.count < selection.appIDs.count { selection = open.isEmpty ? .everything : .apps(open) }
        voiceInRecording = false; voiceLive = false; echoWarning = false; voiceCut = false; silence = nil
        ticker?.invalidate(); ticker = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        onRecordingChanged?(false)
        // Write first, show second: the chip appears only once the file is final on disk.
        Task.detached(priority: .userInitiated) {
            // Finishing takes ~50 ms. If the HAL ever hangs, publish anyway after 4 s: the file is
            // written progressively (fragmented .m4a / RF64 .wav) and already playable.
            finish(rec, timeout: 4)
            let duration = rec.duration
            await MainActor.run {
                self.applyWaitingVoiceChoice()
                // The file is found where it is now (its folder may have been renamed or moved) and published there.
                let url = Files.locate(pending).flatMap { try? Files.publish(located: $0, finalName: final.lastPathComponent) }
                prefs.removeObject(forKey: "inProgress"); prefs.removeObject(forKey: "inProgressBookmark")
                guard let url else {
                    // Its drive went away: say so, and keep it to publish when the drive is back or at next launch.
                    self.setPending(self.pendingList() + [pending])
                    self.saveFailed = true; self.failedSave = pending
                    if self.recorder == nil, self.phase != .ready { self.phase = .ready }
                    return
                }
                let capture = Capture(url: url, duration: duration, bytes: Files.size(url), note: note, sourceApp: source)
                if note == Self.sleepNote { self.sleepCapture = capture }
                self.show(capture)
            }
        }
    }

    func resume() {
        guard let rec = recorder, phase == .paused else { return }
        if !target.appIDs.isEmpty, !target.appIDs.contains(where: apps.isOpen) { return }   // all still closed: stay paused
        guard rec.resume(processes: target.appIDs.isEmpty ? nil : target.appIDs.flatMap(apps.processes(for:))) else {
            NSSound.beep(); return                  // stays paused: try again, as when a recording can't start
        }
        phase = .recording
        targetReopened = false
    }

    private func pauseForQuit() {
        guard let rec = recorder, phase == .recording else { return }
        rec.pause()
        phase = .paused
        targetReopened = false
    }

    /// If onboarding was skipped (permission already granted), touch the save folder once in the
    /// background so any Desktop privacy prompt happens now, never on the main thread at the first stop.
    private func primeFolderAccess() {
        guard phase != .onboarding, !prefs.bool(forKey: "folderPrimed") else { return }
        let path = folder.path
        Task.detached(priority: .utility) {
            _ = try? FileManager.default.contentsOfDirectory(atPath: path)
            prefs.set(true, forKey: "folderPrimed")
        }
    }

    /// After a crash the half-written file is still on disk under its hidden name. At launch it joins the
    /// pending list at once (so a recording started right away keeps its own record), then is revealed.
    private func recoverInterrupted() {
        if let paths = prefs.stringArray(forKey: "inProgress"), paths.count == 2 {
            setPending(pendingList() + [Pending(hidden: paths[0], final: paths[1], bookmark: prefs.data(forKey: "inProgressBookmark"))])
            prefs.removeObject(forKey: "inProgress"); prefs.removeObject(forKey: "inProgressBookmark")
        }
        recoverPending()
    }

    /// Publishes every pending file that can be reached, off the main thread. One on a drive that isn't
    /// connected stays on the list for when it is; one that is gone for good is dropped.
    private func recoverPending() {
        guard !recovering else { recoverAgain = true; return }       // a drive mounted mid-pass: look again after
        let list = pendingList()
        guard !list.isEmpty else { return }
        recovering = true; recoverAgain = false
        Task.detached(priority: .utility) {
            var kept: [Pending] = [], saved: [Pending] = [], found: [Capture] = []
            for p in list {
                if let hidden = Files.locate(p) {
                    if let url = try? Files.publish(located: hidden, finalName: URL(fileURLWithPath: p.final).lastPathComponent) {
                        saved.append(p)
                        found.append(Capture(url: url, duration: Files.duration(url), bytes: Files.size(url), recovered: true))
                    } else {
                        kept.append(p)          // there but can't be renamed now (a drive mounted read-only): tried again later
                    }
                } else if Files.onMissingVolume(p) {
                    kept.append(p)
                }
            }
            await MainActor.run {
                let added = self.pendingList().filter { !list.contains($0) }      // saves that failed meanwhile
                self.setPending(kept + added)
                self.recovering = false
                if let failed = self.failedSave, saved.contains(failed) { self.saveFailed = false; self.failedSave = nil }
                if let newest = found.last { if self.phase == .ready { self.show(newest) } else { self.recoveredWaiting = newest } }
                if self.recoverAgain { self.recoverPending() }
            }
        }
    }

    private func applyWaitingVoiceChoice() {
        guard let choice = voiceChoiceWaiting else { return }
        voiceChoiceWaiting = nil; choice()
    }

    private func pendingList() -> [Pending] {
        prefs.data(forKey: "pending").flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
    }
    private func setPending(_ list: [Pending]) {
        if list.isEmpty { prefs.removeObject(forKey: "pending") } else { prefs.set(try? JSONEncoder().encode(list), forKey: "pending") }
    }

    /// Silence while recording. Said, and cleared, as it happens: after 10 s if nothing has been heard
    /// yet (a muted app, protected audio, the wrong source), after a minute once sound has been heard.
    /// And if the tap hears nothing while the source is playing, the tap is rebuilt: a macOS 26 tap can
    /// keep calling back with zeros after a sample-rate switch or AirPods sleep/wake. A rebuild during
    /// real silence costs nothing (the gap is written as silence), so it is tried with growing pauses.
    private func watchSilence(_ rec: Recorder) {
        let quiet = rec.secondsSinceSound
        let now: Silence? = rec.heardSound ? (quiet >= 60 ? .aMinute : nil) : (quiet >= 10 ? .notYet : nil)
        if now != silence { silence = now }
        guard quiet >= 2 else { silentRebuilds = 0; return }
        let ids = target.appIDs
        // Strong sign: our separate level meter hears the source. Weak sign: macOS says it is playing.
        let heardElsewhere = ids.isEmpty ? apps.apps.keys.contains(where: apps.isSounding) : ids.contains(where: apps.isSounding)
        let processes = ids.isEmpty ? HAL.processObjects().filter { $0 != ownProcess } : ids.flatMap(apps.processes(for:))
        let playing = processes.contains(where: HAL.isRunningOutput)
        let due: Double
        if heardElsewhere { due = 2 + 4 * Double(silentRebuilds) }
        else if playing { due = 5 * pow(2, Double(min(silentRebuilds, 6))) }
        else { return }
        if quiet >= due { silentRebuilds += 1; rec.rebuild() }
    }

    // MARK: Chip

    private func show(_ capture: Capture) {
        chipHovered = false             // a chip removed under the pointer never reports the pointer leaving
        chip = capture
        phase = .finished
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleWhenIdle() }
        }
    }

    private func settleWhenIdle() {
        if chipHovered {
            settleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.settleWhenIdle() }
            }
        } else { settle() }
    }

    func settle() {
        settleTimer?.invalidate()
        chipHovered = false
        chip = nil
        if phase == .finished { phase = .ready }
        if phase == .ready, let waiting = recoveredWaiting { recoveredWaiting = nil; show(waiting) }
    }


    func reveal(_ capture: Capture) { NSWorkspace.shared.activateFileViewerSelecting([capture.url]) }

    func trash(_ capture: Capture) {
        NSWorkspace.shared.recycle([capture.url]) { _, _ in }
        if chip == capture { settleTimer?.invalidate(); chipHovered = false; chip = nil; if phase == .finished { phase = .ready } }
    }

    func copyFile() {
        guard let capture = chip else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([capture.url as NSURL])
    }

    // MARK: Permission

    func continueOnboarding() {
        let folder = folder
        AudioCapturePermission.request { granted in
            if granted { Task { @MainActor in self.accessConfirmed = true } }
            // Touch the save folder now, so a Desktop privacy prompt (if any) happens here, never at the first stop.
            _ = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            Task { @MainActor in
                prefs.set(true, forKey: "onboarded")
                self.phase = .ready
                self.recheckAccess()
            }
        }
    }

    func allowAccess() { AudioCapturePermission.openSettings() }

    func recheckAccess() {
        permission = AudioCapturePermission.status
        noAccess = permission == .denied
        updateMetering()
    }

    /// Settings' "System audio" button: ask if macOS never asked, otherwise open the right Settings pane.
    func requestAccess() {
        guard AudioCapturePermission.status == .undetermined, !accessAllowed else { AudioCapturePermission.openSettings(); return }
        AudioCapturePermission.request { granted in
            Task { @MainActor in
                if granted { self.accessConfirmed = true }
                self.recheckAccess()
                if self.phase == .onboarding { self.phase = .ready }
            }
        }
    }

    private func updateMetering() {
        apps.metering = windowVisible && phase != .onboarding && AudioCapturePermission.status != .denied
    }

    // MARK: Ticker while live

    private func startTicker() {
        tickCount = 0
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker?.tolerance = 0.02
    }

    private func tick() {
        guard let rec = recorder else { return }
        tickCount += 1
        elapsed = rec.duration
        if let hiddenURL { bytes = Files.size(hiddenURL) }
        onTick?(elapsed)

        if !target.appIDs.isEmpty {
            // Several apps: keep recording while any is open; pause only when all have quit.
            let processes = target.appIDs.flatMap(apps.processes(for:))
            let alive = target.appIDs.contains(where: apps.isOpen)
            switch phase {
            case .recording:
                if !alive { pauseForQuit() } else if !processes.isEmpty { rec.updateProcesses(processes) }
            case .paused:
                if alive != targetReopened { targetReopened = alive }
            default: break
            }
        }
        if phase == .recording { rec.reviveIfStalled(); watchSilence(rec) } else if silence != nil { silence = nil }
        if voiceInRecording {
            let micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if phase == .recording { rec.setVoice(device: micAllowed ? voiceDevice() : nil) }
            let live = phase == .recording && rec.voiceActive
            if live != voiceLive { voiceLive = live }
            let echo = live && !voiceCut && rec.echoDetected
            if echo != echoWarning { echoWarning = echo }
        }
        if tickCount % 8 == 0 { recheckAccess() }
        if rec.writeFailed { stop(note: String(localized: "Stopped, write error")); return }
        if tickCount % 20 == 0, let dir = finalURL?.deletingLastPathComponent(), Files.freeBytes(dir) < 500_000_000 {
            stop(note: String(localized: "Stopped, disk almost full"))
        }
    }

    var _debugState: String { "isStarting=\(isStarting) recorder=\(recorder != nil) phase=\(phase) chip=\(chip != nil)" }

    /// Development renders only: an accent in place of the system's, the window drawn as key, spectrum bands.
    var debugAccent: Color?
    var debugKey = false
    /// Development renders only: your voice shown as included (and live while "recording").
    func _debugVoice(_ ids: Set<String>, live: Bool) {
        voiceApps = ids; voiceInRecording = live; voiceLive = live
    }
    var debugEdge: Double?
    @ObservationIgnored var debugBands: [Float]?
    @ObservationIgnored var debugVoiceLevel: Float = 0

    /// Development renders only: show a status line without the event behind it.
    func _debugStatus(noAccess: Bool = false, echo: Bool = false, silence: Silence? = nil, reopened: Bool = false, saveFailed: Bool = false) {
        self.noAccess = noAccess; echoWarning = echo; self.silence = silence; targetReopened = reopened; self.saveFailed = saveFailed
    }

    /// Development only: the chip's trash button without touching any file.
    func _debugTrashChip(_ capture: Capture) {
        if chip == capture { settleTimer?.invalidate(); chipHovered = false; chip = nil; if phase == .finished { phase = .ready } }
    }

    func _debugSet(phase: Phase? = nil, elapsed: Double? = nil, bytes: Int64? = nil, chip: Capture? = nil) {
        if let elapsed { self.elapsed = elapsed }
        if let bytes { self.bytes = bytes }
        if let chip { self.chip = chip; self.phase = .finished }
        if let phase { self.phase = phase }
    }

    /// Read by the spectrum at display rate.
    func spectrum() -> (bands: [Float], clipped: Bool) {
        if recorder == nil, phase == .recording, let debugBands { return (debugBands, false) }
        guard let recorder, phase == .recording else { return ([], false) }
        return (recorder.bands, recorder.takeClipped())
    }

    private func persistSelection() {
        prefs.set(selection.appID, forKey: "lastSource")
        prefs.set(selection.appIDs, forKey: "lastSources")
    }
}

/// Runs `Recorder.finish` on its own thread and waits at most `timeout` seconds.
private func finish(_ rec: Recorder, timeout: Double) {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { try? rec.finish(); done.signal() }
    _ = done.wait(timeout: .now() + timeout)
}

/// The running app's own code signature: its unique hash, and its team (none for an ad hoc signature).
enum CodeSignature {
    struct Identity { let cdhash: String; let team: String? }
    static var current: Identity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return Identity(cdhash: unique.map { String(format: "%02x", $0) }.joined(), team: dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }
    /// Forgets this app's microphone grant (only its own), as `tccutil reset` does from Terminal.
    static func resetMicrophoneGrant() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Microphone", id]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
}
