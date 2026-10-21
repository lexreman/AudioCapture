import AppKit
import AudioCaptureKit
import AVFoundation
import CoreAudio
import SwiftUI

/// `AudioCapture --selftest <out-dir> <tone-binary>`: drives the real engine and window,
/// writes report.json plus PNG snapshots of each window state, then quits. Development only.
/// --selftest, --silencetest and --twice also need a small tone-playing helper, passed by path on the
/// command line; it isn't part of this repository.
@MainActor
enum SelfTest {
    static var arguments: (out: URL, tone: String)? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--selftest"), a.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: a[i + 1]), a[i + 2])
    }

    static var snapshotDir: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshots"), a.count > i + 1 else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }

    /// Renders every window state without touching audio (no permission needed).
    static func snapshots(model: AppModel, window: NSWindow, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var frames: [String: String] = [:]
        func snap(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(900))
            // SwiftUI's own renderer: text and layout exactly as laid out (AppKit-backed layers and glass are not drawn).
            let content = WindowContent { _ in }.environment(model).environment(\.colorScheme, .dark)
                .background(Color(red: 0.118, green: 0.118, blue: 0.125))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let cg = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            }
            frames[name] = NSStringFromRect(window.frame)
        }
        let sample = out.appendingPathComponent("Zen - 14-10-2026, 15.32.m4a")
        FileManager.default.createFile(atPath: sample.path, contents: Data(count: 9_500_000))
        model.phase = .onboarding; await snap("a-onboarding")
        model.phase = .ready; await snap("b-ready")
        model._debugSet(phase: .recording, elapsed: 42, bytes: 6_300_000); await snap("c-recording")
        model._debugSet(phase: .paused, elapsed: 42, bytes: 6_300_000); await snap("d-paused")
        model._debugSet(chip: Capture(url: sample, duration: 63, bytes: 9_500_000)); await snap("e-finished")
        model.settle(); await snap("f-ready-last")
        let realFolder = model.folder
        for (i, name) in ["Recordings", "Podcast Interviews 2026", "Client Projects · Final Mixes", "Very Long Folder Name For Every Single Capture Ever Made"].enumerated() {
            let dir = out.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            model.folder = dir; await snap("g-folder-\(i)")
        }
        model.folder = realFolder
        let data = try? JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: out.appendingPathComponent("frames.json"))
        NSApp.terminate(nil)
    }

    static var silenceTest: (out: URL, tone: String)? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--silencetest"), a.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: a[i + 1]), a[i + 2])
    }

    /// Silence and sleep. Part 1 records a tool that plays digital silence for 4 s, then a sine at
    /// -100 dBFS (inaudible, not zero): nothing is heard at first, sound is seen once it plays, and a
    /// tap rebuild mid-recording keeps the file on wall-clock time. Part 2 records Everything into
    /// <out> for 2 s, announces sleep and wake, and checks the file is saved with its note; the file
    /// is deleted unread.
    static func silence(model: AppModel, out: URL, tone: String) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var r: [String: Any] = [:]
        func wait(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tone)
        p.arguments = ["4", "12"]
        try? p.run()
        await wait(0.6)
        let obj = HAL.processObject(pid: p.processIdentifier)
        r["toneProcess"] = Int(obj)
        let url = out.appendingPathComponent("silence.wav")
        let rec = Recorder(source: .app([obj]), format: .wav, url: url)
        let t0 = Date()
        do { try rec.start() } catch { r["startError"] = "\(error)" }
        await wait(2.5)
        r["at2_5_heard"] = rec.heardSound
        r["at2_5_quiet"] = rec.secondsSinceSound
        await wait(0.5)
        rec.rebuild()
        await wait(3.5)
        r["at6_5_heard"] = rec.heardSound
        r["at6_5_quiet"] = rec.secondsSinceSound
        await wait(1.5)
        try? rec.finish()
        r["wall"] = Date().timeIntervalSince(t0)
        r["duration"] = rec.duration
        p.terminate()
        try? FileManager.default.removeItem(at: url)

        let realFolder = model.folder, realFormat = model.format, realSelection = model.selection
        model.folder = out; model.format = .wav; model.selection = .everything
        model.start()
        await wait(2)
        r["sleep_phaseBefore"] = "\(model.phase)"
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await wait(1.5)
        r["sleep_phaseAfter"] = "\(model.phase)"
        r["sleep_note"] = model.chip?.note ?? "-"
        let saved = model.chip?.url
        r["sleep_fileExists"] = saved.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        model.settle()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await wait(0.5)
        r["wake_chipShownAgain"] = model.chip?.note == AppModel.sleepNote
        if let saved { try? FileManager.default.removeItem(at: saved) }
        model.folder = realFolder; model.format = realFormat; model.selection = realSelection
        let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: out.appendingPathComponent("silence.json"))
        NSApp.terminate(nil)
    }

    static var setupShotDir: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--setupshots"), a.count > i + 1 else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }

    /// Other people's setups: the real window and Settings in light, dark and both Increase Contrast
    /// appearances, every accent colour, at 1× and 2×. Drawn from the real views (AppKit layers
    /// included) as the key window would be; writes PNGs plus shots.json, then quits.
    static func setupShots(model: AppModel, window: NSWindow, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var shots: [[String: String]] = []
        func wait(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        func capture(_ w: NSWindow, _ name: String, scale: CGFloat) {
            guard let view = w.contentView?.superview else { return }
            func drawMeters(_ v: NSView) { (v as? SpectrumNSView)?.renderForCapture(); v.subviews.forEach(drawMeters) }
            drawMeters(view)
            let b = view.bounds
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 6), pixelsHigh: Int(b.height * 6),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = b.size
            view.cacheDisplay(in: b, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }
        let realSelection = model.selection
        model.debugKey = true
        let realContrast = model.increasedContrast
        model.debugBands = Self.musicBands
        if let first = model.visibleAppIDs.first { model.selection = .app(first) }
        let appearances: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua),
            ("dark-contrast", .accessibilityHighContrastDarkAqua), ("light-contrast", .accessibilityHighContrastAqua)]
        let accents: [(String, NSColor)] = [("blue", .systemBlue), ("purple", .systemPurple), ("pink", .systemPink), ("red", .systemRed),
            ("orange", .systemOrange), ("yellow", .systemYellow), ("green", .systemGreen), ("graphite", .systemGray)]
        func shot(_ group: String, _ label: String, _ name: String, scale: CGFloat = 1, settings: Bool = false) async {
            await wait(1.2)
            if settings {
                let w = AppDelegate.makeSettingsWindow(model: model, showsAccessRow: false, drawnAsKey: true)
                w.appearance = NSApp.appearance
                await wait(0.5)
                capture(w, name, scale: scale)
                w.close()
                window.makeKeyAndOrderFront(nil)
            } else {
                capture(window, name, scale: scale)
            }
            shots.append(["group": group, "label": label, "file": name + ".png", "scale": "\(Int(scale))"])
        }
        for (an, ap) in appearances {
            NSApp.appearance = NSAppearance(named: ap)
            window.appearance = NSApp.appearance
            model.increasedContrast = an.hasSuffix("contrast")
            model.debugAccent = Color(nsColor: .systemBlue)
            model._debugSet(phase: .ready); await shot("appearance", "\(an) · ready", "\(an)-ready")
            model._debugSet(phase: .recording, elapsed: 42, bytes: 6_300_000); await shot("appearance", "\(an) · recording", "\(an)-recording")
            model._debugSet(phase: .ready); await shot("appearance", "\(an) · Settings", "\(an)-settings", settings: true)
        }
        if CommandLine.arguments.contains("--edgesonly") {
            shots = []
            for (an, ap) in appearances.suffix(2) {
                NSApp.appearance = NSAppearance(named: ap)
                window.appearance = NSApp.appearance
                model.increasedContrast = true
                for edge in [0.35, 0.22, 0.14] {
                    model.debugEdge = edge
                    model._debugSet(phase: .ready); await shot("edge", "\(an) · edge \(Int(edge * 100)) %", "edge-\(an)-\(Int(edge * 100))")
                }
            }
            model.debugEdge = nil
        }
        for (an, ap) in appearances.prefix(CommandLine.arguments.contains("--edgesonly") ? 0 : 2) {
            NSApp.appearance = NSAppearance(named: ap)
            window.appearance = NSApp.appearance
            model.increasedContrast = false
            for (cn, color) in accents {
                model.debugAccent = Color(nsColor: color)
                model._debugSet(phase: .ready); await shot("accent", "\(an) · \(cn)", "accent-\(an)-\(cn)")
            }
            model.debugAccent = Color(nsColor: .systemBlue)
            model._debugSet(phase: .ready); await shot("retina", "\(an) · ready · 2×", "retina-\(an)-ready", scale: 2)
            model._debugSet(phase: .recording, elapsed: 42, bytes: 6_300_000); await shot("retina", "\(an) · recording · 2×", "retina-\(an)-recording", scale: 2)
            model._debugSet(phase: .ready); await shot("retina", "\(an) · Settings · 2×", "retina-\(an)-settings", scale: 2, settings: true)
        }
        NSApp.appearance = nil; window.appearance = nil
        model.increasedContrast = realContrast
        model.debugAccent = nil; model.debugKey = false; model.debugBands = nil
        model.selection = realSelection
        let data = try? JSONSerialization.data(withJSONObject: shots, options: [.prettyPrinted])
        try? data?.write(to: out.appendingPathComponent("shots.json"))
        NSApp.terminate(nil)
    }

    /// Renders, the arrow, crash and recovery tests and the diagnostic: off screen, never active,
    /// in the tests settings domain (Prefs.swift).
    static var isBackgroundRun: Bool {
        boardShotDir != nil || setupShotDir != nil || settingsShotDir != nil || snapshotDir != nil || arrowTestFile != nil
            || crashDir != nil || quitSave != nil || layoutTestFile != nil || quitWatch != nil || realCaptureFile != nil || ["--dump-apps", "--recovertest"].contains(where: CommandLine.arguments.contains)
    }

    static var arrowTestFile: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--arrowtest"), a.count > i + 1 else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }

    /// Up and Down through a staged list, as real key presses to the main window (kept off screen,
    /// never active). Writes what each press chose, then quits.
    static func arrowTest(model: AppModel, window: NSWindow, out: URL) async {
        model.apps._debugStage(["com.apple.Safari", "com.hnc.Discord", "com.apple.podcasts", "com.apple.Music", "com.apple.TV"],
                               playing: ["com.apple.Safari": 0.5])
        model.listRows = 3
        model.phase = .ready
        model.selection = .everything
        func press(_ code: UInt16, _ name: String, _ flags: NSEvent.ModifierFlags = [.numericPad, .function]) async -> String {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code)!
            NSApp.postEvent(e, atStart: false)
            try? await Task.sleep(for: .milliseconds(150))
            let chosen = model.selection == .everything ? "Everything" : model.selection.appIDs.joined(separator: "+")
            return "\(name) -> \(chosen)"
        }
        var log = ["order: Everything, " + model.visibleAppIDs.joined(separator: ", ")]
        for _ in 0..<7 { log.append(await press(125, "down")) }
        for _ in 0..<7 { log.append(await press(126, "up")) }
        log.append(await press(125, "cmd-down (ignored)", [.numericPad, .function, .command]))
        log.append(await press(125, "down with Caps Lock on", [.numericPad, .function, .capsLock]))
        model.selection = .apps(["com.apple.Safari", "com.apple.podcasts"])
        log.append(await press(125, "down from Safari+Podcasts"))
        model.phase = .onboarding
        log.append(await press(126, "up on the first-launch screen (ignored)"))
        model.phase = .ready
        model._debugSet(phase: .recording, elapsed: 1, bytes: 1)
        log.append(await press(125, "down while recording (locked)"))
        model._debugSet(phase: .ready)
        try? (log.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static var boardShotDir: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--boardshots"), a.count > i + 1 else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }

    /// The GitHub overview's screenshots: Apple's own apps staged in the list (never the person's),
    /// dark and light, default blue accent, 3× (scaled down to exact sizes later). Writes PNGs, then quits.
    static let offscreen = NSPoint(x: -30_000, y: -30_000)

    /// One moment of music as the app's own analyser shows it: a song-like mix (kick, bass, chords,
    /// a voice, hi-hats) through SpectrumAnalyzer's math, just after a kick.
    static let musicBands: [Float] = [0.63, 0.86, 0.86, 0.92, 0.92, 0.86, 0.75, 0.64, 0.58, 0.51, 0.64, 0.62, 0.67, 0.56,
                                      0.54, 0.65, 0.59, 0.43, 0.42, 0.53, 0.37, 0.38, 0.30, 0.18, 0.15, 0.13, 0.10, 0.08]

    static func boardShots(model: AppModel, window mainWindow: NSWindow, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A capture window that tells AppKit it draws at 6x, so text, icons and layers render natively
        // at that resolution (a normal window draws at its screen's scale, then only gets enlarged).
        let window = CaptureWindow(contentRect: NSRect(x: 0, y: 0, width: mainWindow.frame.width, height: mainWindow.frame.height),
                                   styleMask: mainWindow.styleMask, backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Follows its content's height, as the real window does.
        let host = NSHostingView(rootView: WindowContent { [weak window] h in
            DispatchQueue.main.async {
                guard let window, h > 0, abs(window.frame.height - h) > 0.5 else { return }
                window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: window.frame.width, height: h)), display: false)
            }
        }.environment(model).modifier(DebugLook(model: model)))
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(NSRect(origin: Self.offscreen, size: mainWindow.frame.size), display: false)
        // On screen in the window list (so it is the active window and its layers animate), but far
        // outside every display: nothing appears.
        window.makeKeyAndOrderFront(nil)
        func wait(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        func capture(_ w: NSWindow, _ name: String, appearance: NSAppearance.Name, scale: CGFloat = 3) async {
            NSApp.appearance = NSAppearance(named: appearance); w.appearance = NSApp.appearance
            await wait(1.2)
            // The capture window takes the real window's size, which has already fitted its content.
            if w === window, abs(w.frame.height - mainWindow.frame.height) > 0.5 {
                w.setFrame(NSRect(origin: Self.offscreen, size: mainWindow.frame.size), display: false)
                await wait(0.6)
            }
            guard let view = w.contentView?.superview else { return }
            func drawMeters(_ v: NSView) { (v as? SpectrumNSView)?.renderForCapture(); v.subviews.forEach(drawMeters) }
            drawMeters(view)
            let b = view.bounds
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 6), pixelsHigh: Int(b.height * 6),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = b.size
            view.cacheDisplay(in: b, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }
        // Three well-known apps whose sound people keep: a browser, calls, shows.
        let safari = "com.apple.Safari", discord = "com.hnc.Discord", podcasts = "com.apple.podcasts"
        model.apps._debugStage([safari, discord, podcasts], playing: [safari: 0.55, discord: 0.3])
        model.listRows = 3
        model.debugKey = true
        model.debugAccent = Color(nsColor: .systemBlue)
        model.debugBands = Self.musicBands
        let folder = out.appendingPathComponent("Audio Capture")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.folder = folder
        // Icon style is read once per process, so each look is its own run ("--look light"); the light
        // run is launched with "-AppleIconAppearanceTheme Regular", as a light Mac has by default.
        let a = CommandLine.arguments
        let only = a.firstIndex(of: "--look").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        for look in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] where only == nil || only == look.0 {
            model._debugVoice([], live: false)
            model.selection = .app(safari)
            model._debugSet(phase: .ready); await capture(window, "\(look.0)-pick", appearance: look.1)
            model._debugSet(phase: .recording, elapsed: 161, bytes: 5_200_000); await capture(window, "\(look.0)-recording", appearance: look.1)
            let file = folder.appendingPathComponent(Files.baseName(source: "Safari", date: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 21, minute: 4))!) + ".m4a")   // in this Mac's time format
            FileManager.default.createFile(atPath: file.path, contents: Data(count: 5_400_000))
            model._debugSet(chip: Capture(url: file, duration: 168, bytes: 5_400_000, sourceApp: safari)); await capture(window, "\(look.0)-done", appearance: look.1)
            model.settle()
            model.selection = .app(discord)
            model._debugVoice([discord], live: true)
            model.debugVoiceLevel = 0.3                                  // speaking: the badge's microphone is bright
            model._debugSet(phase: .recording, elapsed: 754, bytes: 24_000_000); await capture(window, "\(look.0)-voice", appearance: look.1)
            await capture(window, "\(look.0)-voice-6x", appearance: look.1, scale: 6)
            model._debugSet(phase: .ready)
            model._debugVoice([], live: false)
            let w = AppDelegate.makeSettingsWindow(model: model, showsAccessRow: false, drawnAsKey: true, highResolution: true)
            await capture(w, "\(look.0)-settings", appearance: look.1)
            w.close()
            window.makeKeyAndOrderFront(nil)
            // "--statuses": every status line and corner button, to check each language's length.
            if CommandLine.arguments.contains("--statuses") {
                func status(_ name: String, _ setup: () -> Void) async {
                    setup(); await capture(window, "\(look.0)-status-\(name)", appearance: look.1)
                }
                model.selection = .app(safari)
                await status("noaccess") { model._debugSet(phase: .ready); model._debugStatus(noAccess: true) }
                await status("notyet") { model._debugSet(phase: .recording, elapsed: 12, bytes: 200_000); model._debugStatus(silence: .notYet) }
                await status("aminute") { model._debugStatus(silence: .aMinute) }
                await status("echo") { model._debugStatus(echo: true) }
                await status("closed") { model._debugSet(phase: .paused); model._debugStatus() }
                await status("reopened") { model._debugStatus(reopened: true) }
                await status("closedmany") { model.selection = .apps([safari, discord]); model._debugStatus() }
                model.selection = .app(safari)
                model._debugSet(phase: .ready); model._debugStatus()
                await status("notopen") { model.apps._debugClose(podcasts); model.selection = .app(podcasts) }
                await status("unknown") { model.selection = .app("io.github.lexreman.nonexistent") }
                model.selection = .app(safari)
                await status("sleepnote") {
                    model._debugSet(chip: Capture(url: file, duration: 168, bytes: 5_400_000, note: AppModel.sleepNote, sourceApp: safari))
                }
                await status("recovered") {
                    model._debugSet(chip: Capture(url: file, duration: 168, bytes: 5_400_000, recovered: true, sourceApp: safari))
                }
                // The longest chip: several long app names, a duplicate number, a note and over an hour.
                let long = folder.appendingPathComponent(Files.baseName(source: "Google Chrome + Microsoft Teams + Zoom", date: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 21, minute: 4))!) + " 2.m4a")
                FileManager.default.createFile(atPath: long.path, contents: Data(count: 1000))
                await status("longnote") {
                    model._debugSet(chip: Capture(url: long, duration: 3768, bytes: 90_000_000, note: String(localized: "Stopped, disk almost full"), sourceApp: safari))
                }
                await status("longsleep") {
                    model._debugSet(chip: Capture(url: long, duration: 3768, bytes: 90_000_000, note: AppModel.sleepNote, sourceApp: safari))
                }
                await status("savefailed") { model.settle(); model._debugSet(phase: .ready); model._debugStatus(saveFailed: true) }
                model._debugStatus()
                // Fewer apps than the smallest list: no other app open, then one.
                model.settle(); model._debugSet(phase: .ready); model.selection = .everything
                await status("noapps") { model.apps._debugStage([], playing: [:]) }
                await status("oneapp") { model.apps._debugStage([safari], playing: [safari: 0.55]) }
                model.settle()
                model._debugSet(phase: .ready)
            }
        }
        NSApp.terminate(nil)
    }

    static var settingsShotDir: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--settingsshots"), a.count > i + 1 else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }

    /// Renders the Settings window (title bar included) for each format, with and without the access row,
    /// never putting it on screen.
    static func settingsShots(model: AppModel, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let realFormat = model.format, realFolder = model.folder
        let folder = out.appendingPathComponent("Audio Capture")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.folder = folder
        for missing in [false, true] {
            for format in CaptureFormat.allCases {
                model.format = format
                let w = AppDelegate.makeSettingsWindow(model: model, showsAccessRow: missing, drawnAsKey: true)
                w.appearance = NSAppearance(named: .darkAqua)
                try? await Task.sleep(for: .milliseconds(400))
                guard let frame = w.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(missing ? "missing" : "allowed")-\(format.rawValue).png"))
                print("\(missing ? "missing" : "allowed") \(format.rawValue) \(NSStringFromSize(w.frame.size))")
                w.close()
            }
        }
        model.format = realFormat; model.folder = realFolder
        NSApp.terminate(nil)
    }

    static var twice: (out: URL, app: String)? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--twice"), a.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: a[i + 1]), a[i + 2])
    }

    /// Two recordings of a real app in a row (WAV), each saved; reports phases and timing.
    static func recordTwice(model: AppModel, out: URL, appPath: String) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ s: String) { log.append(String(format: "%.2f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + s) }
        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
        try? await Task.sleep(for: .seconds(2))
        model.windowVisible = true
        model.apps.refresh()
        model.folder = out; model.format = .wav
        model.select(.app("io.github.lexreman.audiocapture.tone"))
        for round in 1...6 {
            model.select(round % 3 == 0 ? .everything : .app("io.github.lexreman.audiocapture.tone"))
            note("round \(round) start \(model.selection), phase=\(model.phase) unavailable=\(model.selectionUnavailable) permission=\(AudioCapturePermission.status)")
            model.primary()
            try? await Task.sleep(for: .seconds(2))
            note("after 2 s: phase=\(model.phase) elapsed=\(model.elapsed)")
            if model.phase != .recording { note("NOT RECORDING: \(model._debugState)") }
            let t = Date()
            model.primary()
            while model.phase != .finished && Date().timeIntervalSince(t) < 10 { try? await Task.sleep(for: .milliseconds(20)) }
            note("stop -> phase=\(model.phase) after \(String(format: "%.3f", Date().timeIntervalSince(t))) s, chip=\(model.chip?.url.lastPathComponent ?? "nil")")
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        note("files: \(files.sorted())")
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("twice.log"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static var layoutTestFile: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--layouttest"), a.count > i + 1 else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }

    /// Quick stop, start, stop, delete, start, played through the window's states (no audio): logs every
    /// window height, so a resize mid-sequence shows up as a number.
    static func layoutTest(model: AppModel, window: NSWindow, out: URL) async {
        if model.phase == .onboarding { model.phase = .ready }
        let safari = "com.apple.Safari", discord = "com.hnc.Discord"
        model.apps._debugStage([safari, discord], playing: [safari: 0.5])
        model.selection = .app(safari)
        try? await Task.sleep(for: .seconds(1.5))
        var heights: [String] = [], last: CGFloat = -1
        let t0 = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated {
                let h = window.frame.height
                if abs(h - last) > 0.25 { heights.append(String(format: "%.3f s  %.1f", Date().timeIntervalSince(t0), h)); last = h }
            }
        }
        func pause(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        let file = URL(fileURLWithPath: "/tmp/x.m4a")
        func stop() { model._debugSet(chip: Capture(url: file, duration: 3, bytes: 90_000, sourceApp: safari)) }
        func start() async { if model.phase == .finished { model.settle() }; await pause(0.12); model._debugSet(phase: .recording, elapsed: 0, bytes: 0) }
        model._debugSet(phase: .recording, elapsed: 1, bytes: 1000); await pause(1)
        stop(); await pause(0.4)
        await start(); await pause(0.6)
        stop(); await pause(0.4)
        if let chip = model.chip { model._debugTrashChip(chip) }; await pause(0.1)
        await start(); await pause(0.6)
        stop(); await pause(7.5)            // the chip settles on its own
        await start(); await pause(1)
        timer.invalidate()
        try? (["steps: rec, stop, start, stop, delete, start, stop, settle, start", "window heights:"] + heights).joined(separator: "\n")
            .write(to: out, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static var quitSave: (out: URL, app: String)? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--quitsave"), a.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: a[i + 1]), a[i + 2])
    }

    /// Records a (silent) app, quits it mid-recording, saves: the quit app must leave the selection.
    static func quitAndSave(model: AppModel, out: URL, appPath: String) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log: [String] = []
        let id = "io.github.lexreman.audiocapture.quittest"
        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
        try? await Task.sleep(for: .seconds(3))
        model.windowVisible = true; model.apps.refresh()
        model.folder = out
        model.select(.app(id)); model.primary()
        try? await Task.sleep(for: .seconds(2))
        log.append("recording: phase=\(model.phase) selection=\(model.selection)")
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
        try? await Task.sleep(for: .seconds(3))
        log.append("app quit: phase=\(model.phase)")
        model.stop()
        let t = Date()
        while model.phase != .finished && Date().timeIntervalSince(t) < 10 { try? await Task.sleep(for: .milliseconds(20)) }
        log.append("saved: phase=\(model.phase) selection=\(model.selection) listed=\(model.visibleAppIDs.contains(id)) file=\(model.chip?.url.lastPathComponent ?? "nil")")
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("quitsave.log"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static var realCaptureFile: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--realcapture"), a.count > i + 1 else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }

    /// The window as the window server composes it (frame, edges, shadow), through the call that lets an app
    /// image its own windows; it is looked up at run time because newer SDKs hide it. Development only.
    static func realCapture(model: AppModel, window: NSWindow, out: URL) async {
        let look = CommandLine.arguments.firstIndex(of: "--look").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        NSApp.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua); window.appearance = NSApp.appearance
        if model.phase == .onboarding { model.phase = .ready }
        model.apps._debugStage(["com.apple.Safari", "com.hnc.Discord", "com.apple.podcasts"], playing: ["com.apple.Safari": 0.55])
        model.selection = .app("com.apple.Safari")
        try? await Task.sleep(for: .seconds(2))
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        var note = "no image"
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(sym, to: CreateImage.self)
            // including this window only, at the best resolution, with its frame and shadow
            if let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 3)?.takeRetainedValue() {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
                note = "\(image.width)x\(image.height)"
            }
        } else { note = "symbol missing" }
        note += " innerRadius=\(model.innerRadius)"
        try? note.write(to: out.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static var quitWatch: (out: URL, ids: [String])? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--quitwatch"), a.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: a[i + 1]), a[i + 2].split(separator: ",").map(String.init))
    }

    /// Opens each app hidden, waits until it is listed, quits it, and times how long its row stays.
    static func quitWatch(model: AppModel, out: URL, ids: [String]) async {
        if model.phase == .onboarding { model.phase = .ready }
        model.windowVisible = true
        var log: [String] = []
        func listed(_ id: String) -> Bool { model.visibleAppIDs.contains(id) }
        for id in ids {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { log.append("\(id): not installed"); continue }
            let config = NSWorkspace.OpenConfiguration(); config.activates = false; config.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            var t = Date()
            while !listed(id) && Date().timeIntervalSince(t) < 10 { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .seconds(2))
            let wasListed = listed(id)
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
            t = Date()
            var gone: Double?
            while Date().timeIntervalSince(t) < 8 {
                if !listed(id) { gone = Date().timeIntervalSince(t); break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let alive = NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
            if !wasListed { log.append("\(id): never listed (no audio connection)") }
            else if let gone { log.append(String(format: "%@: left the list %.2f s after quit", id, gone)) }
            else { log.append("\(id): STILL LISTED 8 s after quit (app still running: \(alive))") }
        }
        try? log.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static var clickDir: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--clicktest"), a.count > i + 1 else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }

    /// Real mouse events into the window (through AppKit and SwiftUI hit-testing, like a person's clicks).
    static func clickTest(model: AppModel, window: NSWindow, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        model.folder = out; model.format = .aac
        model.listRows = 3                     // a previous run may have left the test window taller
        model.select(.everything)
        var log: [String] = []
        func click(_ p: NSPoint) {
            let number = Int.random(in: 1...1_000_000)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        try? await Task.sleep(for: .seconds(1.5))
        // Calibration: click the second visible app row; the selection must change.
        let rowY = window.frame.height - (Metric.titlebar + Metric.row + Metric.rowGap + Metric.row + Metric.rowGap + Metric.row / 2)
        click(NSPoint(x: 120, y: rowY)); try? await Task.sleep(for: .milliseconds(500))
        log.append("calibration row click: selection=\(model.selection) (expect an app)")
        model.select(.everything); try? await Task.sleep(for: .milliseconds(300))
        let button = NSPoint(x: Metric.inset + Metric.band / 2, y: Metric.inset + Metric.band / 2)   // window coords, bottom-left origin
        log.append("apps listed: \(model.visibleAppIDs.count), window h=\(window.frame.height)")
        if let cv = window.contentView {
            for p in [button, NSPoint(x: 20, y: 20), NSPoint(x: 50, y: 50)] {
                var v = cv.hitTest(cv.convert(p, from: nil)); var chain: [String] = []
                while let x = v { chain.append(String(describing: type(of: x))); v = x.superview }
                log.append("hitTest \(p): \(chain.prefix(4).joined(separator: " < "))")
            }
            func dump(_ v: NSView, _ d: Int) { if d < 6 { for c in v.subviews { log.append(String(repeating: "  ", count: d) + "\(type(of: c)) \(NSStringFromRect(c.convert(c.bounds, to: nil)))"); dump(c, d + 1) } } }
            dump(cv, 0)
        }
        for cycle in 1...3 {
            click(button); try? await Task.sleep(for: .seconds(1.5))
            log.append("cycle \(cycle) after click 1: phase=\(model.phase) selection=\(model.selection)")
            click(button); try? await Task.sleep(for: .seconds(0.8))
            log.append("cycle \(cycle) after click 2: phase=\(model.phase)")
        }
        // While recording, the spectrum sits in the recorded source's tile (Everything here).
        click(button); try? await Task.sleep(for: .seconds(1.5))
        if let cv = window.contentView {
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            let views = all(cv).filter { $0 is SpectrumNSView }
            log.append("spectrum while recording: \(views.map { NSStringFromRect($0.convert($0.bounds, to: nil)) }) (Everything tile is x 6–258, top at \(window.frame.height - Metric.titlebar))")
        }
        click(button); try? await Task.sleep(for: .seconds(0.8))
        // Clicks just below the list (divider zone and the line under it) must not select hidden rows.
        let before = model.selection
        let listBottomFromTop = Metric.titlebar + Metric.row + Metric.rowGap + 3 * Metric.row + 2 * Metric.rowGap
        for dy in [3.0, 10.0, 20.0, 30.0] {
            click(NSPoint(x: 120, y: window.frame.height - listBottomFromTop - dy))
            try? await Task.sleep(for: .milliseconds(300))
        }
        log.append("below-list clicks: selection before=\(before) after=\(model.selection) phase=\(model.phase)")
        // Taller window: a drag snaps to whole rows, never below Everything + 3, never past the app count.
        if let d = NSApp.delegate as? AppDelegate {
            func listHeight() -> CGFloat {
                func find(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.lazy.compactMap(find).first }
                return window.contentView.flatMap(find)?.frame.height ?? 0
            }
            let before = window.frame.height, listBefore = listHeight()
            let got = d.windowWillResize(window, to: NSSize(width: 400, height: before + (Metric.row + Metric.rowGap) * 2.6))
            var f = window.frame; f.origin.y -= got.height - before; f.size = got; window.setFrame(f, display: true)
            try? await Task.sleep(for: .milliseconds(900))
            log.append(String(format: "resize: drag +2.6 rows → window +%.0f pt (2.6 rows snaps to 3: expect +108), width %.0f, rows %d, list %.0f → %.0f pt, window now %.0f", got.height - before, got.width, model.listRows, listBefore, listHeight(), window.frame.height))
            let small = d.windowWillResize(window, to: NSSize(width: 264, height: 120))
            var g = window.frame; g.origin.y -= small.height - g.height; g.size = small; window.setFrame(g, display: true)
            try? await Task.sleep(for: .milliseconds(900))
            log.append(String(format: "resize: shrink to 120 pt → %.0f pt, rows %d (expect 3), list %.0f pt", small.height, model.listRows, listHeight()))
        }
        // Several apps: ⌘ adds/removes, Shift takes the range from the last clicked; a pair records into one file.
        let ids = model.visibleAppIDs
        if ids.count >= 3 {
            model.click(ids[0], modifiers: [])
            model.click(ids[1], modifiers: .command)
            log.append("multi: ⌘-click → \(model.selection.appIDs.count) apps, title \"\(model.selectionName)\"")
            model.click(ids[1], modifiers: .command)
            log.append("multi: ⌘-click again → \(model.selection.appIDs.count) app")
            model.click(ids[0], modifiers: [])
            model.click(ids[2], modifiers: .shift)
            log.append("multi: Shift-click → \(model.selection.appIDs.count) apps (expect 3), title \"\(model.selectionName)\"")
            model.click(ids[0], modifiers: []); model.click(ids[1], modifiers: .command)
            let open = model.selection.appIDs.allSatisfy { model.apps.isOpen($0) }
            if open {
                model.start(); try? await Task.sleep(for: .seconds(1.5))
                let phase = model.phase
                model.stop(); try? await Task.sleep(for: .seconds(1.2))
                log.append("multi: recording two apps → phase \(phase), file \"\(model.chip?.name ?? "none")\"")
            }
            model.select(.everything)
        }
        // Trackpad scrolling over the list: must follow the fingers freely, then settle on a row once released.
        func scrollOffset() -> String {
            guard let cv = window.contentView else { return "?" }
            func find(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.lazy.compactMap(find).first }
            guard let sv = find(cv) else { return "no NSScrollView" }
            return String(format: "%.1f", sv.contentView.bounds.origin.y)
        }
        func scroll(_ dy: Int32, phase: Int64) {
            let p = window.convertPoint(toScreen: NSPoint(x: 120, y: rowY))
            let primary = NSScreen.screens.first?.frame.height ?? 0
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
            e.location = CGPoint(x: p.x, y: primary - p.y)
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if let ns = NSEvent(cgEvent: e) {
                // What NSWindow.sendEvent does for a scroll: hit-test the point, hand the event to that view.
                if let cv = window.contentView, let target = cv.hitTest(cv.convert(NSPoint(x: 120, y: rowY), from: nil)) {
                    received += 1
                    target.scrollWheel(with: ns)
                }
            }
        }
        nonisolated(unsafe) var received = 0
        let counter = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { received += 1; return $0 }
        if let cv = window.contentView {
            func find(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.lazy.compactMap(find).first }
            var v = cv.hitTest(cv.convert(NSPoint(x: 120, y: rowY), from: nil)); var chain: [String] = []
            while let x = v { chain.append(String(describing: type(of: x)).prefix(40).description); v = x.superview }
            log.append("row point (120, \(rowY)) hits: \(chain.prefix(6).joined(separator: " < "))")
            if let sv = find(cv) { log.append("scroll view \(type(of: sv)) frame=\(NSStringFromRect(sv.convert(sv.bounds, to: nil))) doc=\(NSStringFromRect(sv.documentView?.frame ?? .zero))") }
        }
        log.append("scroll: apps=\(model.visibleAppIDs) offset at rest=\(scrollOffset())")
        for (label, deltas) in [("short drag (≈0.3 row)", [-4, -4, -4]), ("long drag (≈1.4 rows)", [-5, -10, -10, -10, -10, -5]), ("drag back up (≈2 rows)", [10, 15, 15, 15, 15])] {
            for (n, d) in deltas.enumerated() {
                scroll(Int32(d), phase: n == 0 ? 1 : 2)
                try? await Task.sleep(for: .milliseconds(16))
            }
            try? await Task.sleep(for: .milliseconds(60))
            let during = scrollOffset()
            scroll(0, phase: 4)
            try? await Task.sleep(for: .seconds(1))
            log.append("\(label): while held=\(during) after release=\(scrollOffset())  (scroll events received: \(received))")
            if let cv = window.contentView {
                func find(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.lazy.compactMap(find).first }
                if let sv = find(cv) { log.append("   clip=\(NSStringFromRect(sv.contentView.bounds)) doc=\(NSStringFromRect(sv.documentView?.frame ?? .zero)) insets=\(sv.contentInsets.top),\(sv.contentInsets.bottom) docVisible=\(NSStringFromRect(sv.documentVisibleRect))") }
            }
            var picks: [String] = []
            for slot in 0..<3 {
                let y = window.frame.height - (Metric.titlebar + Metric.row + Metric.rowGap + Metric.rowGap + CGFloat(slot) * (Metric.row + Metric.rowGap) + Metric.row / 2)
                let n = Int.random(in: 1...1_000_000)
                let idsBefore = model.visibleAppIDs
                for (type, wait) in [(NSEvent.EventType.leftMouseDown, 80), (.leftMouseUp, 300)] {
                    if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 120, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: 1) { window.sendEvent(e) }
                    try? await Task.sleep(for: .milliseconds(wait))
                }
                picks.append(model.selection.appID.flatMap { idsBefore.firstIndex(of: $0) }.map(String.init) ?? "none")
                model.select(.everything); try? await Task.sleep(for: .milliseconds(200))
            }
            log.append("   clicks on visible slots 0,1,2 picked indices \(picks)")
        }
        if let counter { NSEvent.removeMonitor(counter) }
        // Rows inside the scroll view must still take a click: press, hold briefly, release (like a finger).
        let firstRowY = window.frame.height - (Metric.titlebar + Metric.row + Metric.rowGap + Metric.rowGap + Metric.row / 2)
        let number = Int.random(in: 1...1_000_000)
        for (type, wait) in [(NSEvent.EventType.leftMouseDown, 80), (.leftMouseUp, 400)] {
            if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 120, y: firstRowY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1) {
                window.sendEvent(e)
            }
            try? await Task.sleep(for: .milliseconds(wait))
        }
        // Control: the Everything row (outside the scroll view, always worked by hand), clicked the same way.
        model.select(.app(model.visibleAppIDs[1])); try? await Task.sleep(for: .milliseconds(300))
        let everythingY = window.frame.height - (Metric.titlebar + Metric.row / 2)
        let n2 = Int.random(in: 1...1_000_000)
        for (type, wait) in [(NSEvent.EventType.leftMouseDown, 80), (.leftMouseUp, 400)] {
            if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 120, y: everythingY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: n2, clickCount: 1, pressure: 1) { window.sendEvent(e) }
            try? await Task.sleep(for: .milliseconds(wait))
        }
        log.append("control: Everything row click → selection=\(model.selection) (expect everything)")
        if let cv = window.contentView {
            var v = cv.hitTest(cv.convert(NSPoint(x: 120, y: firstRowY), from: nil)); var chain: [String] = []
            while let x = v { chain.append(String(describing: type(of: x)).prefix(30).description); v = x.superview }
            log.append("first-row point y=\(firstRowY) hits: \(chain.prefix(5).joined(separator: " < ")) offset=\(scrollOffset())")
        }
        let n3 = Int.random(in: 1...1_000_000)
        for (type, wait) in [(NSEvent.EventType.leftMouseDown, 80), (.leftMouseUp, 400)] {
            if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 120, y: rowY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: n3, clickCount: 1, pressure: 1) { window.sendEvent(e) }
            try? await Task.sleep(for: .milliseconds(wait))
        }
        log.append("second-row click after scrolling: selection=\(model.selection) (second row is \(model.visibleAppIDs[1]))")
        log.append("row click after scrolling: selection=\(model.selection) (top row is \(model.visibleAppIDs.first ?? "-"))")
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("click.log"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static var crashDir: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--crashtest"), a.count > i + 1 else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }

    /// Starts a real recording, then dies with SIGKILL mid-write. The next launch must recover the file.
    static func crash(model: AppModel, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        model.folder = out
        model.selection = .everything
        model.start()
        try? await Task.sleep(for: .seconds(3))
        kill(getpid(), SIGKILL)
    }

    static func run(model: AppModel, window: NSWindow, out: URL, tone: String) async {
        if AudioCapturePermission.status != .granted {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in AudioCapturePermission.request { _ in c.resume() } }
        }
        var report: [String: Any] = ["permission": "\(AudioCapturePermission.status)"]
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        model.folder = out
        func snap(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(700))
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            report["frame_\(name)"] = NSStringFromRect(window.frame)
        }
        func wait(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

        // A 1 kHz tone source.
        let toneProcess = Process()
        toneProcess.executableURL = URL(fileURLWithPath: tone)
        toneProcess.arguments = ["1000", "0.05", "t30"]
        toneProcess.standardOutput = FileHandle.nullDevice
        try? toneProcess.run()
        await wait(1.0)

        await snap("1-ready")

        // 1. Everything, lossless.
        model.selection = .everything
        model.format = .lossless
        model.start()
        await wait(3.5)
        await snap("2-recording")
        model.stop()
        while model.phase != .finished { await wait(0.05) }
        await snap("3-finished")
        if let c = model.chip { report["everything"] = analyze(c) }
        model.settle()
        await snap("4-ready-last")

        // 2. One process (the tone helper), with a pause in the middle: paused time must not be in the file.
        let obj = HAL.processObject(pid: toneProcess.processIdentifier)
        let url = out.appendingPathComponent("tone-only.wav")
        let rec = Recorder(source: .app([obj]), format: .wav, url: url)
        do {
            try rec.start()
            await wait(2.0); rec.pause()
            await wait(2.0); rec.resume()
            await wait(2.0); try rec.finish()
            report["appPauseResume"] = analyze(Capture(url: url, duration: rec.duration, bytes: Files.size(url)))
        } catch { report["appPauseResume"] = "error \(error)" }

        // 3. Visual states that need a running app to reach naturally.
        model.phase = .paused
        await snap("5-paused")
        model.phase = .ready

        toneProcess.terminate()
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: out.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }

    /// Duration, level and the measured frequency of the 1 kHz tone (speed check).
    private static func analyze(_ c: Capture) -> [String: Any] {
        var r: [String: Any] = ["file": c.url.lastPathComponent, "reportedDuration": c.duration, "bytes": c.bytes]
        guard let file = try? AVAudioFile(forReading: c.url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { r["error"] = "unreadable"; return r }
        let n = Int(buf.frameLength), sr = file.processingFormat.sampleRate
        r["fileDuration"] = Double(n) / sr; r["sampleRate"] = sr; r["channels"] = Int(file.processingFormat.channelCount)
        var crossings = 0, sq = 0.0, nonzero = 0
        let a = n / 4, b = n * 3 / 4
        for i in a..<b {
            let x = ch[i]; sq += Double(x * x); if x != 0 { nonzero += 1 }
            if i > a && ch[i - 1] <= 0 && x > 0 { crossings += 1 }
        }
        r["middleHalfFreqHz"] = Double(crossings) * sr / Double(b - a)
        r["middleHalfRmsDb"] = 10 * log10(max(sq / Double(b - a), 1e-20))
        r["middleHalfNonzero"] = Double(nonzero) / Double(b - a)
        return r
    }
}

/// Development renders only: applies AppModel's debug accent and key-window look; inert otherwise.
struct DebugLook: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        // Only touched when set, so the person's own accent is never overridden.
        if let accent = model.debugAccent {
            look(content.environment(\.accent, accent))
        } else {
            look(content)
        }
    }
    private func look(_ v: some View) -> some View {
        v.transformEnvironment(\.appearsActive) { if model.debugKey { $0 = true } }
            .transformEnvironment(\.controlActiveState) { if model.debugKey { $0 = .key } }
    }
}

/// Development renders only: a window that reports 6x, so AppKit and SwiftUI draw it at that resolution.
final class CaptureWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 6 }
    // Drawn as the window in use (coloured window buttons), though it is never really frontmost.
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}
