import AppKit
import AudioCaptureKit
import CoreAudio
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--voicecheck") {
            let r = VoiceMixer.selfCheck() + "\n"
            if CommandLine.arguments.count > i + 1 { try? r.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8) } else { print(r) }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--permission-status") {
            let line = "\(AudioCapturePermission.status)\n"
            if CommandLine.arguments.count > i + 1 { try? line.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8) } else { print(line) }
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    /// The app's name is a name: it stays the same in every language, as Apple's own apps' names do.
    static let appName = "Audio Capture"
    private let model = AppModel()
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var lastBadgeSecond = -1
    private var quitting = false
    private var arrowKeys: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        model.onRecordingChanged = { [weak self] on in self?.recordingChanged(on) }
        // The recording Dock icon follows a change of icon style or appearance made while recording
        // (a moment later, once macOS has redrawn the bundle icon it is matched to).
        NotificationCenter.default.addObserver(forName: IconStyle.didChange, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard let self, self.model.isLive, NSApp.activationPolicy() == .regular else { return }
                    NSApp.applicationIconImage = Self.recordingIcon()
                }
            }
        }
        model.onTick = { [weak self] t in self?.badge(t) }
        model.onPinned = { [weak self] on in self?.applyPin(on) }
        applyPin(model.pinned)
        // Up and Down move through the list. Only plain arrows in the main window; everything else passes on.
        arrowKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock]).isEmpty
            else { return event }
            switch event.keyCode {
            case 126: self.model.moveSelection(by: -1); return nil
            case 125: self.model.moveSelection(by: 1); return nil
            default: return event
            }
        }
        // Development renders draw off screen and never take the keyboard: the person keeps working.
        if SelfTest.isBackgroundRun {
            window.setFrameOrigin(SelfTest.offscreen)
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--dump-apps"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            // The diagnostic listens as if the window were shown; "--as-hidden" checks that a hidden window doesn't.
            if !CommandLine.arguments.contains("--as-hidden") { model.windowVisible = true }
            // "--dump-after N": read the list N seconds in (default 6), e.g. well after an app quit.
            let after = CommandLine.arguments.firstIndex(of: "--dump-after").flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [model] in
                let rows = model.apps.apps.values.map { "\($0.name)\tprocs=\($0.processes.count)\trunningOutput=\($0.runningOutput)\trunning=\($0.isRunning)\tsounding=\(model.apps.isSounding($0.id))\tlastSound=\(model.apps.lastSoundTime($0.id).map { String(format: "%.1fs ago", -$0.timeIntervalSinceNow) } ?? "never")" }
                let text = "heardAudio=\(model.apps.heardAudio) permission=\(AudioCapturePermission.status) taps=\(model.apps.debugTaps)\nmetering=\(model.apps.metering) windowVisible=\(model.windowVisible) phase=\(model.phase)\nvisible=\(model.visibleAppIDs)\n" + rows.sorted().joined(separator: "\n") + "\n"
                // Raw audio clients as macOS reports them: pid, responsible pid, output running, bundle.
                let raw = HAL.processObjects().map { obj -> String in
                    let pid = HAL.pid(of: obj), resp = HAL.responsiblePID(pid)
                    let bundle = HAL.string(obj, kAudioProcessPropertyBundleID) ?? "-"
                    let owner = NSRunningApplication(processIdentifier: resp)
                    return "\(pid)\tresp=\(resp)\tout=\(HAL.isRunningOutput(obj))\t\(bundle)\towner=\(owner?.bundleIdentifier ?? "-") policy=\(owner?.activationPolicy.rawValue ?? -1)"
                }
                try? (text + "\nraw audio clients:\n" + raw.sorted().joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        if let f = SelfTest.realCaptureFile {
            Task { await SelfTest.realCapture(model: model, window: window, out: f) }
        }
        if let q = SelfTest.quitWatch {
            Task { await SelfTest.quitWatch(model: model, out: q.out, ids: q.ids) }
        }
        if let dir = SelfTest.clickDir {
            if model.phase == .onboarding { model.phase = .ready }
            Task { await SelfTest.clickTest(model: model, window: window, out: dir) }
        } else if let f = SelfTest.layoutTestFile {
            Task { await SelfTest.layoutTest(model: model, window: window, out: f) }
        } else if let q = SelfTest.quitSave {
            if model.phase == .onboarding { model.phase = .ready }
            Task { await SelfTest.quitAndSave(model: model, out: q.out, appPath: q.app) }
        } else if let t = SelfTest.twice {
            if model.phase == .onboarding { model.phase = .ready }
            Task { await SelfTest.recordTwice(model: model, out: t.out, appPath: t.app) }
        } else if let dir = SelfTest.crashDir {
            Task { await SelfTest.crash(model: model, out: dir) }
        } else if let t = SelfTest.silenceTest {
            if model.phase == .onboarding { model.phase = .ready }
            Task { await SelfTest.silence(model: model, out: t.out, tone: t.tone) }
        } else if let file = SelfTest.arrowTestFile {
            Task { await SelfTest.arrowTest(model: model, window: window, out: file) }
        } else if let dir = SelfTest.boardShotDir {
            if model.phase == .onboarding { model.phase = .ready }
            Task { await SelfTest.boardShots(model: model, window: window, out: dir) }
        } else if let dir = SelfTest.setupShotDir {
            if model.phase == .onboarding { model.phase = .ready }
            Task { await SelfTest.setupShots(model: model, window: window, out: dir) }
        } else if let dir = SelfTest.settingsShotDir {
            Task { await SelfTest.settingsShots(model: model, out: dir) }
        } else if let dir = SelfTest.snapshotDir {
            Task { await SelfTest.snapshots(model: model, window: window, out: dir) }
        } else if let test = SelfTest.arguments {
            if model.phase == .onboarding { model.phase = .ready }
            Task { await SelfTest.run(model: model, window: window, out: test.out, tone: test.tone) }
        }
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metric.width, height: 260),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        window.delegate = self
        window.title = "Audio Capture"

        let container = NSView(frame: window.contentLayoutRect)
        let host = NSHostingView(rootView: WindowContent { [weak self] h in self?.fitHeight(h) }.environment(model).modifier(DebugLook(model: model)))
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        if #available(macOS 27, *) {
            // Measures the system's concentric radius at our 6 pt inset (16 − 6 on macOS 27); never hard-coded.
            let probe = ConcentricProbe(frame: NSRect(x: Metric.inset, y: Metric.inset, width: 40, height: 40))
            probe.onRadius = { [weak self] r in self?.model.innerRadius = r }
            container.addSubview(probe, positioned: .below, relativeTo: host)
        } else {
            // Older macOS can't report it: its window corners are 10 pt (26: 16), so the inner radius is that minus the inset.
            let windowRadius: CGFloat = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 16 : 10
            model.innerRadius = max(4, windowRadius - Metric.inset)
        }
        // One display link for every moving layer in the window.
        let tickerHost = NSView(frame: .zero)
        container.addSubview(tickerHost)
        window.contentView = container
        Ticker.shared.attach(to: tickerHost)

        if !window.setFrameUsingName("AudioCaptureMain"), let screen = NSScreen.main {
            let vf = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: vf.maxX - Metric.width - 24, y: vf.midY - 130))
        }
        if !testRun { window.setFrameAutosaveName("AudioCaptureMain") }   // tests never move the person's window
        window.standardWindowButton(.zoomButton)?.isHidden = true    // nothing to zoom: taller by dragging only
        // Equal min and max width: macOS offers no sideways resize, so the side edges show no resize cursor.
        window.minSize = NSSize(width: Metric.width, height: 100)
        window.maxSize = NSSize(width: Metric.width, height: CGFloat.greatestFiniteMagnitude)
    }

    /// Height only, in whole rows: from Everything + 3 apps up to every audio app, never empty space.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let step = Metric.row + Metric.rowGap
        func list(_ n: Int) -> CGFloat { n > 0 ? CGFloat(n) * Metric.row + CGFloat(n - 1) * Metric.rowGap : 0 }
        let count = model.visibleAppIDs.count
        let current = sender.frame.height
        guard count > 3 else { return NSSize(width: Metric.width, height: current) }
        let fixed = current - list(min(count, model.listRows))
        let rows = min(count, max(3, Int(((frameSize.height - fixed + Metric.rowGap) / step).rounded())))
        if rows != model.listRows { model.listRows = rows }
        return NSSize(width: Metric.width, height: fixed + list(rows))
    }

    /// The window follows its content's height, keeping its top edge where the person put it.
    /// Called from SwiftUI's layout pass, so the resize waits for the next run-loop turn and animates
    /// without blocking: `setFrame(animate: true)` spins a nested loop inside the update and crashes it.
    private func fitHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        let pending = pendingHeight != nil
        pendingHeight = height
        guard !pending else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let height = self.pendingHeight else { return }
            self.pendingHeight = nil
            var frame = window.frame
            guard abs(frame.height - height) > 0.5 else { return }
            let top = frame.maxY
            frame.size.height = height
            frame.origin.y = top - height
            if window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                }
            } else {
                window.setFrame(frame, display: true)
            }
        }
    }
    private var pendingHeight: CGFloat?

    private func applyPin(_ on: Bool) {
        window.level = on ? .floating : .normal
        window.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenNone]
                                       : [.fullScreenNone, .fullScreenDisallowsTiling]
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump-apps") { return }   // the diagnostic always listens
        let visible = window.occlusionState.contains(.visible)
        model.windowVisible = visible
        Ticker.shared.paused = !visible
    }

    /// Closing while recording hides the app completely (no Dock icon, no ⌘Tab); the recording continues.
    /// Opening Audio Capture again brings the window back. Closing while idle quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isLive {
            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !window.isVisible { showWindow() }
    }

    private func showWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            if model.isLive { NSApp.applicationIconImage = Self.recordingIcon() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: Dock

    private func recordingChanged(_ on: Bool) {
        NSApp.applicationIconImage = on ? Self.recordingIcon() : nil
        lastBadgeSecond = -1
        NSApp.dockTile.badgeLabel = on ? "0:00" : nil
        if !on, NSApp.activationPolicy() != .regular, !quitting { showWindow() }
    }

    /// The recording icon in the light or dark version the Dock shows now: the bundle icon as macOS
    /// draws it in the person's icon style is sampled, so every style and setting is followed.
    private static func recordingIcon() -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        var light = false
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { icon.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64)) }
            NSGraphicsContext.restoreGraphicsState()
            // The tile's corner area, inside the shape and outside the bubble.
            light = (rep.colorAt(x: 14, y: 14)?.brightnessComponent ?? 0) > 0.6
        }
        return AppIcon.image(recording: true, light: light)
    }

    private func badge(_ t: Double) {
        let s = Int(t)
        guard s != lastBadgeSecond else { return }
        lastBadgeSecond = s
        NSApp.dockTile.badgeLabel = Format.time(t)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        switch model.phase {
        case .recording, .paused: menu.addItem(withTitle: String(localized: "Stop Recording"), action: #selector(stopFromMenu), keyEquivalent: "")
        case .onboarding: return nil
        default:
            menu.autoenablesItems = false
            let item = menu.addItem(withTitle: model.recordTitle, action: #selector(recordFromMenu), keyEquivalent: "")
            item.isEnabled = !model.selectionUnavailable
        }
        return menu
    }
    @objc private func stopFromMenu() { model.stop() }
    @objc private func recordFromMenu() { model.start() }

    // MARK: Quit: a live recording is always finalized first, never a question

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isLive else { return .terminateNow }
        quitting = true
        model.stop()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(5)   // never hang a quit
            while self.model.isLive && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }   // saved, or couldn't be
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Menus (standard only)

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: String(localized: "About \(Self.appName)"), action: #selector(showAbout), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide \(Self.appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit \(Self.appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(copyCapture), keyEquivalent: "c")
        editItem.submenu = edit

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let win = NSMenu(title: String(localized: "Window"))
        win.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }

    @objc private func copyCapture() { model.copyFile() }

    /// The standard About panel: icon, name, one plain version, copyright, a source link.
    @objc private func showAbout() {
        let credits = NSAttributedString(string: String(localized: "Source on GitHub"), attributes: [
            .link: URL(string: "https://github.com/lexreman/AudioCapture")!,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: "",
            .credits: credits,
        ])
    }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = Self.makeSettingsWindow(model: model) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The window takes the form's own height, so the margin below the last row matches the one above the first.
    static func makeSettingsWindow(model: AppModel, showsAccessRow: Bool? = nil, drawnAsKey: Bool = false, highResolution: Bool = false) -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(showsAccessRow: showsAccessRow, drawnAsKey: drawnAsKey).environment(model).modifier(DebugLook(model: model)))
        host.sizingOptions = [.preferredContentSize]
        let w: NSWindow = highResolution ? CaptureWindow(contentViewController: host) : NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = String(localized: "\(appName) Settings")
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }
}

/// Settings geometry. One rule: anything sitting inside a rounded shape keeps the same gap on every side
/// and takes the outer radius minus that gap, so every corner is concentric with the one around it.
private enum SG {
    static let margin: CGFloat = 16          // window edge (and title bar) to the card, sides and top
    static let cardRadius: CGFloat = 12
    static let inset: CGFloat = 6            // card edge to a control: top, trailing, bottom
    static let control: CGFloat = 24         // every control's height
    static let controlRadius = cardRadius - inset        // 6
    static let thumbInset: CGFloat = 2       // control edge to the selected segment
    static let thumbRadius = controlRadius - thumbInset  // 4
    static let row = control + 2 * inset     // 36
    static let labelInset: CGFloat = 12      // label text from the card's leading edge
    static let segment: CGFloat = 72
    static let fill = Color.primary.opacity(0.06)
    static let fillHover = Color.primary.opacity(0.11)
    static let card = Color.primary.opacity(0.035)
    static let hairline = Color.primary.opacity(0.09)
}

/// A control-shaped tile: 24 tall, radius 6, the same fill as the format control's track.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration) }
    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .frame(height: SG.control)
                .background(RoundedRectangle(cornerRadius: SG.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.15) : hover ? SG.fillHover : SG.fill))
                .contrastEdge(RoundedRectangle(cornerRadius: SG.controlRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: SG.controlRadius, style: .continuous))
                .onHover { hover = $0 }
        }
    }
}

/// The save folder as a tile; a click opens the folder picker. The icon sits 4 from the tile's top,
/// bottom and leading edge, the same gap all round.
private struct FolderTile: View {
    let name: String
    let folder: URL
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                SystemIcon(path: folder.path, size: 16)
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, 4).padding(.trailing, 10)
        }
        .buttonStyle(TileButtonStyle())
        .help(String(localized: "Choose where recordings are saved"))
        .accessibilityLabel(String(localized: "Save to \(name)"))
        .accessibilityHint(String(localized: "Opens a folder picker"))
    }
}

/// The format choice drawn to the same geometry as everything else: track radius 6, selected segment
/// inset 2 with radius 4. Behaves as a native segmented picker for VoiceOver.
private struct FormatControl: View {
    @Binding var selection: CaptureFormat
    @Environment(\.controlActiveState) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accent) private var accent
    @Namespace private var thumb
    var body: some View {
        let cases = CaptureFormat.allCases
        // Equal segments, at least 72 wide, wider when a translated name needs it (12 pt of air around the longest).
        let segment = max(SG.segment, cases.map { Self.width($0.localizedTitle) }.max().map { ($0 + 24).rounded(.up) } ?? 0)
        HStack(spacing: 0) {
            ForEach(Array(cases.enumerated()), id: \.element) { i, format in
                let selected = format == selection
                Button { withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12)) { selection = format } } label: {
                    Text(format.localizedTitle)
                        .foregroundStyle(selected && active != .inactive ? Color.white : Color.primary)
                        .frame(width: segment, height: SG.control - 2 * SG.thumbInset)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: SG.thumbRadius, style: .continuous)
                                    .fill(active == .inactive ? Color.primary.opacity(0.2) : accent)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .trailing) {
                    // A divider only between two unselected segments, as AppKit draws it.
                    if i < cases.count - 1, !selected, cases[i + 1] != selection {
                        Rectangle().fill(Color.primary.opacity(0.16)).frame(width: 1, height: 12).offset(x: 0.5)
                    }
                }
            }
        }
        .padding(SG.thumbInset)
        .background(RoundedRectangle(cornerRadius: SG.controlRadius, style: .continuous).fill(SG.fill))
        .contrastEdge(RoundedRectangle(cornerRadius: SG.controlRadius, style: .continuous))
        .accessibilityRepresentation {
            Picker("Format", selection: $selection) {
                ForEach(cases, id: \.self) { Text($0.localizedTitle).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

extension FormatControl {
    static func width(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
    }
}

/// The microphone's level in recordings: −12 to +12 dB in 3 dB steps; the middle mark is as recorded.
struct MicLevelSlider: View {
    @Binding var level: Double
    var body: some View {
        Slider(value: $level, in: -12...12, step: 3) {
            Text("Microphone")
        } minimumValueLabel: {
            Text("Quieter").foregroundStyle(.secondary)
        } maximumValueLabel: {
            Text("Louder").foregroundStyle(.secondary)
        }
        .labelsHidden()
        .frame(width: 230)
        .help(String(localized: "How loud the microphone is in your recordings. Nothing changes in other apps."))
        .accessibilityValue(String(localized: "\(Int(level)) dB"))
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    private var updates = Updates.shared
    /// Snapshots only: forces the access row on or off.
    var showsAccessRow: Bool? = nil
    /// Snapshots only: draws as the key window would (offscreen windows are never key).
    var drawnAsKey = false
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Only when GitHub has a newer version: no notification, nothing to see otherwise.
                if let release = updates.available {
                    row("Version \(release.version) is available") {
                        Button("Download") { NSWorkspace.shared.open(release.page) }
                            .padding(.horizontal, 10).buttonStyle(TileButtonStyle())
                    }
                    hairline
                }
                // Only while it's missing, on one line; once allowed there is nothing to say.
                if showsAccessRow ?? !model.accessAllowed {
                    row("System audio") {
                        Button(model.permission == .denied ? String(localized: "Open System Settings…") : String(localized: "Allow…"), action: model.requestAccess)
                            .padding(.horizontal, 10).buttonStyle(TileButtonStyle())
                    }
                    hairline
                }
                row("Save to") { FolderTile(name: model.folderName, folder: model.folder, choose: chooseFolder) }
                hairline
                row("Format") { FormatControl(selection: $model.format) }
                hairline
                row("Microphone") { MicLevelSlider(level: $model.micLevel) }
            }
            .background(RoundedRectangle(cornerRadius: SG.cardRadius, style: .continuous).fill(SG.card))
            .contrastEdge(RoundedRectangle(cornerRadius: SG.cardRadius, style: .continuous))
            // What an hour costs, last in the window and centred, the same gap above and below.
            Text(model.format.hourEstimate)
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, SG.margin - 3)  // 16 from the card to the digits' tops and from the baseline to the edge
        }
        .padding([.horizontal, .top], SG.margin)
        .font(.system(size: 13))
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .transformEnvironment(\.controlActiveState) { if drawnAsKey { $0 = .key } }
        .onAppear { model.recheckAccess(); updates.check() }
    }

    private func row(_ label: LocalizedStringKey, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 0)
            control()
        }
        .padding(.leading, SG.labelInset).padding(.trailing, SG.inset)
        .frame(height: SG.row)
    }

    private var hairline: some View {
        SG.hairline.frame(height: 1).padding(.leading, SG.labelInset).padding(.trailing, SG.inset)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = model.folder
        panel.prompt = String(localized: "Use Folder")
        if panel.runModal() == .OK, let url = panel.url { model.folder = url }
    }
}

extension CaptureFormat {
    /// The name shown in Settings: AAC and WAV are format names everywhere; Lossless is a word, translated.
    var localizedTitle: String { self == .lossless ? String(localized: "Lossless") : title }

    /// What one hour costs on disk at 48 kHz stereo. AAC and WAV are fixed rates; lossless depends
    /// on the sound (measured here: 0.41 GB/h for a pure tone, 0.73 GB/h for dense, noisy material).
    var hourEstimate: String {
        switch self {
        case .aac: String(localized: "\(Self.size(256_000 / 8 * 3600)) per hour")
        case .lossless: String(localized: "\(Self.size(400_000_000, digits: 1, unit: false))–\(Self.size(700_000_000, digits: 1)) per hour")
        case .wav: String(localized: "\(Self.size(48_000 * 2 * 4 * 3600)) per hour")
        }
    }
    private static func size(_ bytes: Double, digits: Int? = nil, unit: Bool = true) -> String {
        let gb = bytes >= 1e9 || digits != nil
        let f = NumberFormatter()
        f.maximumFractionDigits = digits ?? (gb ? 1 : 0)
        f.minimumFractionDigits = digits ?? (gb ? 1 : 0)
        let n = f.string(from: NSNumber(value: gb ? bytes / 1e9 : bytes / 1e6)) ?? ""
        return unit ? (gb ? String(localized: "\(n) GB") : String(localized: "\(n) MB")) : n
    }
}

