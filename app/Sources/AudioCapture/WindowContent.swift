import AppKit
import AudioCaptureKit
import SwiftUI

/// Geometry from measured system metrics: window corner 16 pt,
/// traffic lights centred on the corner arc at (16, 16), titlebar 32 pt.
enum Metric {
    static let width: CGFloat = 264
    static let titlebar: CGFloat = 32
    static let inset: CGFloat = 6          // every inner surface; radius = window radius − inset
    static let arc: CGFloat = 16           // corner-arc centreline: pin, divider, right text column
    static let row: CGFloat = 34
    static let rowGap: CGFloat = 2
    static let icon: CGFloat = 20
    static let iconInset = (row - icon) / 2
    static let band: CGFloat = 58
    static let lineGap: CGFloat = 10       // space on each side of the divider = window radius − inset
}

extension Animation {
    /// Every layout change the phase drives (rows, tile, list, bubbles) moves on this one spring.
    static let layout = Animation.spring(duration: 0.35, bounce: 0.12)
}

struct WindowContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Metric.titlebar)
            if model.phase == .onboarding {
                Onboarding()
            } else {
                EverythingRow().padding(.horizontal, Metric.inset)
                AppList()
                // The list ends on a hard edge (no fade); the line gets the room instead: 10 pt on both
                // sides, frame to frame, the same in every state. 10 = the inner radius (16 − 6).
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
                    .padding(.horizontal, Metric.arc).padding(.vertical, Metric.lineGap)
                if let status = StatusBubble.Content(model) {
                    StatusBubble(content: status).padding(.horizontal, Metric.inset).padding(.bottom, Metric.inset)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
                }
                ControlBand()
            }
        }
        .frame(width: Metric.width)
        .overlay(alignment: .topTrailing) { if model.phase != .onboarding { PinButton() } }
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .animation(reduceMotion ? nil : .layout, value: model.phase)        // Reduce Motion: changes land without moving
        .animation(reduceMotion ? nil : .layout, value: model.visibleAppIDs)
    }
}

// MARK: - Titlebar

private struct PinButton: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false
    private let size: CGFloat = 24
    var body: some View {
        Button { model.pinned.toggle() } label: {
            Image(systemName: model.pinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.pinned ? .primary : (hover ? .secondary : .tertiary))
                .frame(width: size, height: size)
                .background(Circle().fill(.primary.opacity(hover ? 0.07 : 0)))     // round, on the corner arc, like the close button
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(model.pinned ? String(localized: "Stop keeping on top") : String(localized: "Keep on top"))
        .accessibilityLabel(model.pinned ? String(localized: "Unpin window") : String(localized: "Keep window on top"))
        .padding(.top, Metric.arc - size / 2).padding(.trailing, Metric.arc - size / 2)   // centre at (W − 16, 16): mirrors the close button
    }
}

// MARK: - Sources

/// Every row is a tile: faint at rest, stronger under the cursor, the system accent when selected
/// (grey while the window isn't active, like every macOS list).
private struct RowBackground: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var active
    @Environment(\.accent) private var accent
    let selected: Bool
    let hover: Bool
    func body(content: Content) -> some View {
        // While recording, the recorded source's tile stops being a bubble: it runs past both window
        // edges (like the wave through the app icon) and carries the spectrum, bars standing on its
        // bottom edge behind the name.
        let live = selected && model.isLive
        let shape = RoundedRectangle(cornerRadius: live ? 0 : model.innerRadius, style: .continuous)
        content.background {
            ZStack {
                if live {
                    // The spectrum draws the tile itself, with the bars cut out to the window background.
                    SpectrumView(tile: NSColor(selectedColor)) { [weak model] in model?.spectrum() ?? ([], false) }
                        .clipShape(shape)
                        .transition(.opacity)
                } else {
                    shape.fill(fill).contrastEdge(shape)
                }
            }
            .padding(.horizontal, live ? -Metric.inset : 0)
            .animation(reduceMotion ? nil : .layout, value: live)
        }
    }
    /// One colour for the selected tile, drawn by SwiftUI at rest and by the spectrum while recording
    /// (bridged, it stays dynamic: `.primary` keeps its 85 % label alpha, the accent follows the system).
    private var selectedColor: Color { active ? accent.opacity(0.32) : Self.ink.opacity(0.14) }
    private var fill: Color { selected ? selectedColor : Self.ink.opacity((hover ? 0.10 : 0.05) * (model.increasedContrast ? 2 : 1)) }
    /// Opaque text colour, so the percentages are literal (`.primary` carries 85 % alpha).
    private static let ink = Color(nsColor: .textColor)
}

/// A row is a real button (clicks, VoiceOver, synthetic events all go through the same path),
/// drawn exactly as the row: no system bezel, no press flash.
private struct RowTap: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        Button(action: action) { content }.buttonStyle(RowButtonStyle())
    }
}
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Right-click a source: "Include my voice", remembered per source. Not while recording.
private struct VoiceMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    let source: Selection
    func body(content: Content) -> some View {
        content.contextMenu {
            Toggle("Include my voice", isOn: Binding(get: { model.voiceIncluded(source) },
                                                     set: { model.setVoiceIncluded($0, for: source) }))
                .disabled(model.isLive)
        }
    }
}

/// A row's right edge: the level marks (hidden on the tile being recorded: its spectrum shows the level).
private struct RowTrailing: View {
    @Environment(AppModel.self) private var model
    let source: Selection
    let name: String
    let selected: Bool
    let level: () -> Float
    var body: some View {
        MarkView(level: level).opacity(model.isLive && selected ? 0 : 1)
    }
}

/// A row's icon. With your voice included the app icon wears a small graphite microphone badge on its
/// corner, on top of the icon.
/// Not included: the app icon alone, as before. The icon never moves.
private struct SourceIcon<Icon: View>: View {
    @Environment(AppModel.self) private var model
    let source: Selection
    let name: String
    let selected: Bool
    @ViewBuilder let icon: Icon
    var body: some View {
        if model.voiceIncluded(source) {
            let live = model.isLive && selected && model.voiceInRecording
            // The badge sits on top of the icon, with no gap around it.
            let badged = ZStack(alignment: .bottomTrailing) {
                icon
                MicBadge(live: live).offset(x: 3, y: 3)
            }
            if live {
                Button { model.voiceCut.toggle() } label: { badged.contentShape(Rectangle()) }
                    .buttonStyle(RowButtonStyle())
                    .help(model.voiceCut ? String(localized: "Your voice is cut. Click to record it again.")
                          : model.voiceLive ? String(localized: "Your voice is recorded. Click to cut it.")
                          : source == .everything ? String(localized: "Your voice joins when the mic is available.")
                          : String(localized: "Your voice joins when \(name) uses the mic."))
                    .accessibilityLabel(model.voiceCut ? String(localized: "Your voice, cut") : String(localized: "Your voice"))
                    .accessibilityHint(model.voiceCut ? String(localized: "Records your voice again") : String(localized: "Cuts your voice from the recording"))
            } else {
                badged.help("Your voice is included")
            }
        } else {
            icon
        }
    }
}

/// The badge: a 10 pt graphite disc with Apple's microphone. While recording it follows your voice,
/// dims while the app isn't using the mic, and shows a slashed mic when cut.
private struct MicBadge: View {
    @Environment(AppModel.self) private var model
    let live: Bool
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.5), Color(white: 0.28)], startPoint: .top, endPoint: .bottom))
            if live {
                VoiceGlyph(state: model.voiceCut ? .cut : (model.voiceLive ? .live : .idle)) { [weak model] in model?.takeVoiceLevel() ?? 0 }
            } else {
                Image(systemName: "mic.fill").font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 10, height: 10)
    }
}

private struct EverythingRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    private static let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    @State private var hover = false
    var body: some View {
        let selected = model.selection == .everything
        let locked = model.isLive && !selected
        HStack(spacing: 8) {
            // Everything is what the app itself captures: its own icon (the bundle's file icon,
            // so it stays the calm version while the Dock shows the recording one).
            SourceIcon(source: .everything, name: String(localized: "Everything"), selected: selected) {
                SystemIcon(Self.appIcon, size: Metric.icon)
            }
            Text("Everything").font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            RowTrailing(source: .everything, name: String(localized: "Everything"), selected: selected) { [weak model] in model?.everythingLevel() ?? 0 }
        }
        .padding(.leading, Metric.iconInset).padding(.trailing, Metric.arc - Metric.inset)   // marks end on x = W − 16
        .frame(height: Metric.row)
        .modifier(RowBackground(selected: selected, hover: hover && !locked))
        .opacity(locked ? model.lockedOpacity(dark: scheme == .dark) : 1)
        .contentShape(Rectangle())
        .modifier(RowTap { model.select(.everything) })
        .modifier(VoiceMenu(source: .everything))
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Everything")
        .accessibilityValue(model.apps.sounding.isEmpty ? String(localized: "Quiet") : String(localized: "Playing"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Three rows at a time. Scrolling is the system's own: it follows the fingers 1:1, carries
/// momentum and rubber-bands at the ends. Only when it comes to rest does it settle on a row
/// boundary (the projected landing point, so a flick never gets dragged back).
private struct AppList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var lastRow = 0
    private let step = Metric.row + Metric.rowGap

    var body: some View {
        let ids = model.visibleAppIDs
        let shown = min(ids.count, model.listRows)
        if shown > 0 {
            let height = CGFloat(shown) * Metric.row + CGFloat(shown - 1) * Metric.rowGap
            let maxOffset = CGFloat(ids.count - shown) * step
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: Metric.rowGap) {
                        ForEach(ids, id: \.self) { id in AppRow(id: id).id(id) }
                    }
                    .padding(.horizontal, Metric.inset)
                    .background(LegacyOffsetReader())
                    .scrollTargetLayout()
                }
                .scrollIndicators(.never)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
                .scrollDisabled(ids.count <= shown)
                .frame(height: height)
                .onScrollOffsetChange { y in
                    offset = y
                    // A light tick as each row passes under the finger (felt only while touching the trackpad).
                    let row = Int(((min(max(y, 0), maxOffset)) / step).rounded())
                    if row != lastRow {
                        lastRow = row
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
                .onHover { model.listHovered = $0 }
                .onChange(of: model.selection) { _, selection in      // an app chosen with the arrows comes into view
                    guard selection.appIDs.count == 1, let id = selection.appID,
                          let i = model.visibleAppIDs.firstIndex(of: id) else { return }
                    let first = Int((offset / step).rounded())
                    guard i < first || i >= first + shown else { return }
                    withAnimation(reduceMotion ? nil : .layout) { proxy.scrollTo(id, anchor: i < first ? .top : .bottom) }
                }
                .onChange(of: model.phase) { _, phase in      // the recorded app is always in view
                    guard phase == .recording || phase == .paused, let id = model.selection.appID,
                          let i = model.visibleAppIDs.firstIndex(of: id) else { return }
                    let first = Int((offset / step).rounded())
                    guard i < first || i >= first + shown else { return }
                    withAnimation(reduceMotion ? nil : .layout) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .padding(.top, Metric.rowGap)
        }
    }
}

private struct AppRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let id: String
    @State private var hover = false
    var body: some View {
        let app = model.apps.apps[id]
        let selected = model.selection.contains(id)
        let locked = model.isLive && !selected
        let closed = !(app?.isRunning ?? false)
        let sounding = model.apps.isSounding(id)
        HStack(spacing: 8) {
            SourceIcon(source: .app(id), name: app?.name ?? id, selected: selected) {
                SystemIcon(app?.icon ?? NSImage(), size: Metric.icon)
                    .saturation(closed ? 0 : 1).opacity(closed ? 0.5 : 1)
            }
            Text(app?.name ?? id).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(closed ? AnyShapeStyle(.tertiary) : (sounding || selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
            Spacer(minLength: 4)
            RowTrailing(source: .app(id), name: app?.name ?? id, selected: selected) { [weak model] in model?.apps.levels[id] ?? 0 }
        }
        .padding(.leading, Metric.iconInset).padding(.trailing, Metric.arc - Metric.inset)
        .frame(height: Metric.row)
        .modifier(RowBackground(selected: selected, hover: hover && !locked))
        .opacity(locked ? model.lockedOpacity(dark: scheme == .dark) : 1)
        .contentShape(Rectangle())
        .modifier(RowTap { model.click(id, modifiers: NSEvent.modifierFlags) })
        .modifier(VoiceMenu(source: .app(id)))
        .onHover { hover = $0 }
        .help(closed ? (app.map { String(localized: "\($0.name) is closed") } ?? String(localized: "This app is closed")) : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app?.name ?? id)
        .accessibilityValue(closed ? String(localized: "Closed") : (sounding ? String(localized: "Playing") : String(localized: "Quiet")))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Control band

private struct ControlBand: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cornerWidth: CGFloat = 0
    var body: some View {
        // The record button never leaves: a finished file sits beside it, so the next recording is one press away.
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 12) {
                RecordButton()
                if model.phase == .finished, let chip = model.chip {
                    FileChip(capture: chip)
                        .padding(.trailing, Metric.inset - Metric.arc)   // chip reaches the 6 pt inset: concentric bottom-right
                        .transition(.asymmetric(insertion: reduceMotion ? .opacity : .offset(x: 10).combined(with: .opacity), removal: .opacity))
                } else {
                    // The corner button sits over the band's right end: the line beside the record button
                    // stops short of it (in every language), with the same 8 pt gap as elsewhere.
                    Info().padding(.trailing, cornerAction == nil ? 0 : max(0, cornerWidth + Metric.inset - Metric.arc + 8))
                }
            }
            .padding(.leading, Metric.inset).padding(.trailing, Metric.arc)
            if model.phase != .finished, let action = cornerAction {
                // The recorded app is gone and can't be resumed: Save is the way on, so it breathes.
                Button(action.title, action: action.run)
                    .buttonStyle(CornerButtonStyle(radius: model.innerRadius, breathes: model.phase == .paused && !model.targetReopened))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cornerWidth = $0 }
                    .padding(.trailing, Metric.inset)
                    .transition(.opacity)
            }
        }
        .frame(height: Metric.band)
        .padding(.bottom, Metric.inset)
    }

    private var cornerAction: (title: String, run: () -> Void)? {
        if model.noAccess { return (String(localized: "Allow"), model.allowAccess) }
        if model.phase == .paused { return (String(localized: "Save"), { model.stop() }) }
        return nil
    }
}

private struct CornerButtonStyle: ButtonStyle {
    let radius: CGFloat
    var breathes = false
    func makeBody(configuration: Configuration) -> some View { CornerButton(configuration: configuration, radius: radius, breathes: breathes) }

    /// Text ends on x = W − 16 (button at the 6 pt inset + 10 pt padding); hovers like every other control.
    /// Breathing: its fill brightens and fades in the record button's rhythm; with Reduce Motion it stays bright.
    private struct CornerButton: View {
        let configuration: Configuration
        let radius: CGFloat
        let breathes: Bool
        @Environment(\.displayScale) private var scale
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hover = false
        @State private var bright = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, Metric.arc - Metric.inset).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.primary.opacity(fill)))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 1 / scale))
                .onHover { hover = $0 }
                .onChange(of: breathes && !reduceMotion, initial: true) { _, on in
                    if on { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true } }
                    else { withAnimation(.easeOut(duration: 0.2)) { bright = false } }
                }
        }
        private var fill: Double {
            if configuration.isPressed { return 0.2 }
            if breathes { return reduceMotion ? 0.24 : (bright ? 0.3 : 0.12) }
            return hover ? 0.18 : 0.12
        }
    }
}

private struct Info: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if model.isLive {
                // The spectrum lives in the recorded source's tile; here only time and size, stacked.
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.time(model.elapsed))
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
                        .foregroundStyle(model.phase == .paused ? .secondary : .primary)
                        .contentTransition(.numericText())
                    Text(Format.bytes(model.bytes)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectionName).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    // Long folder names: drop "Saves to" (the folder icon and tooltip say it), then shrink
                    // up to 20 %, and only past that cut in the middle like Finder, keeping start and end.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Text("Saves to").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize()
                            FolderChip(fit: .full)
                        }
                        FolderChip(fit: .full)
                        FolderChip(fit: .squeezed)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Ready: a small red bubble. Recording: the red square. Paused: the drop, slowly breathing once it can resume.
/// A flat tile in the rows' material, no outline and no glass highlights; brighter on hover and press.
private struct RecordButtonStyle: ButtonStyle {
    let radius: CGFloat
    func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration, radius: radius) }
    private struct Tile: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .textColor).opacity(configuration.isPressed ? 0.16 : hover ? 0.12 : 0.08)))
                .contrastEdge(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hover = $0 }
        }
    }
}

private struct RecordButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: model.innerRadius, style: .continuous)
        Button(action: model.primary) {
            // Red liquid: the fill around an empty square while recording (press to stop); otherwise the drop,
            // what pressing does: record, or resume when paused (then it breathes slowly while it waits).
            LiquidMark(state: model.phase == .recording ? .stop : .drop, radius: model.innerRadius)
                .opacity(model.phase == .paused && breathe && !reduceMotion ? 0.6 : 1)
            .frame(width: Metric.band, height: Metric.band)
            .contentShape(shape)
        }
        .buttonStyle(RecordButtonStyle(radius: model.innerRadius))
        .keyboardShortcut(.space, modifiers: [])
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        // It breathes only while resuming works: with the recorded app gone, Save breathes instead.
        .onChange(of: model.phase == .paused && model.targetReopened, initial: true) { _, resumable in
            breathe = false
            if resumable && !reduceMotion {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true }
            }
        }
        .help(String(localized: "\(help) (Space)"))
        .accessibilityLabel(help)
        .accessibilityValue(model.isLive ? Format.spoken(model.elapsed) : "")
    }

    /// Nothing to record (closed app selected) or nothing to resume yet (recorded app still closed).
    private var disabled: Bool {
        (!model.isLive && model.selectionUnavailable) || (model.phase == .paused && !model.targetReopened)
    }

    private var help: String {
        switch model.phase {
        case .recording: String(localized: "Stop recording")
        case .paused: String(localized: "Resume recording")
        default: model.recordTitle
        }
    }
}

// MARK: - Finished file

private struct FileChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let capture: Capture
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            SystemIcon(path: capture.url.path, size: 26, kind: .audio)
            VStack(alignment: .leading, spacing: 1) {
                // What was recorded on the first line, when on the second: a long list of apps is shortened, never the time.
                let name = Format.nameLines(capture.name)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name.what).truncationMode(.middle)
                    if let when = name.when { Text(when).minimumScaleFactor(0.8) }
                }
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                // Smaller first, then the note alone: the duration gives way before anything is cut.
                ViewThatFits(in: .horizontal) {
                    ForEach([11.5, 10.35, 9.2], id: \.self) { size in Text(meta).font(.system(size: size).monospacedDigit()) }
                    Text(metaShort).font(.system(size: 11.5)).minimumScaleFactor(0.8)
                }
                .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8).padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask {
            // Under the actions the name is cut away, so the chip itself shows through: exactly its colour.
            // (A `.background` fill resolves to windowBackgroundColor, darker than the visible window.)
            Rectangle().overlay(alignment: .topTrailing) {
                if hover { ChipAction.group.blendMode(.destinationOut).padding(ChipAction.margin) }
            }
            .compositingGroup()
        }
        .background(RoundedRectangle(cornerRadius: model.innerRadius, style: .continuous).fill(.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: model.innerRadius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1 / scale))   // one device pixel
        .contrastEdge(RoundedRectangle(cornerRadius: model.innerRadius, style: .continuous))
        .overlay(FileDrag(url: capture.url, tip: String(localized: "Drag to use it, click to show it in Finder. ⌘C copies it."),
                          onClick: { model.reveal(capture) }, onHover: { hover = $0; model.chipHovered = $0 }))
        .overlay(alignment: .topTrailing) {
            if hover {
                HStack(spacing: ChipAction.gap) {
                    ChipAction(symbol: "folder", help: String(localized: "Show in Finder")) { model.reveal(capture) }
                    ChipAction(symbol: "trash", help: String(localized: "Move to Trash")) { model.trash(capture) }
                }
                .padding(ChipAction.gap)
                .padding(ChipAction.margin)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hover)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(([capture.name] + details).joined(separator: ", "))
        .accessibilityHint("Drag to use the file. Click to show it in Finder.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.reveal(capture) }
        .accessibilityAction(named: "Move to Trash") { model.trash(capture) }
    }

    /// Note, duration and size: "Saved at sleep · 2:48 · 5.4 MB".
    private var details: [String] {
        var parts = [Format.time(capture.duration), Format.bytes(capture.bytes)]
        if let note = capture.note { parts.insert(note, at: 0) }
        if capture.recovered { parts.insert(String(localized: "Recovered"), at: 0) }
        return parts
    }
    /// The line under the name: with a note there is room for the note and the duration only (the size is
    /// in Finder); VoiceOver still reads all of it.
    private var meta: String {
        (capture.note != nil || capture.recovered ? Array(details.dropLast()) : details).joined(separator: " · ")
    }
    private var metaShort: String { details.count > 2 ? details[0] : meta }
}

private struct ChipAction: View {
    static let size: CGFloat = 26, gap: CGFloat = 2, margin: CGFloat = 6, groupRadius: CGFloat = 8
    /// The pair's outline: two buttons and the gap around them.
    static var group: some View {
        RoundedRectangle(cornerRadius: groupRadius, style: .continuous)
            .frame(width: 2 * size + 3 * gap, height: size + 2 * gap)
    }
    let symbol: String
    let help: String
    let run: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: Self.size, height: Self.size)
                .foregroundStyle(hover ? .primary : .secondary)
                .background(RoundedRectangle(cornerRadius: Self.groupRadius - Self.gap, style: .continuous)   // concentric in the pair
                    .fill(.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help).accessibilityLabel(help)
    }
}

/// The save folder as a small bubble: click opens it in Finder.
private struct FolderChip: View {
    enum Fit { case full, squeezed }
    @Environment(AppModel.self) private var model
    @State private var hover = false
    let fit: Fit
    var body: some View {
        Button {
            try? FileManager.default.createDirectory(at: model.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(model.folder)
        } label: {
            HStack(spacing: 4) {
                SystemIcon(path: model.folder.path, size: 14)       // even: centres on whole pixels in the 20 pt chip
                if fit == .full {
                    Text(model.folderName).font(.system(size: 11.5)).lineLimit(1).fixedSize()
                } else {
                    MarqueeText(text: model.folderName, hovering: hover)
                }
            }
            .foregroundStyle(hover ? .primary : .secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(hover ? 0.12 : 0.07)))
            .contrastEdge(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hover = $0 }
        .help("Saves to \(model.folderName). Click to open it in Finder.")
        .accessibilityLabel("Save folder, \(model.folderName)")
        .accessibilityHint("Opens the folder in Finder")
    }
}

/// A name too long for its space: shrinks up to 20 %, then is cut in the middle like Finder.
/// Under the cursor it slides at reading pace to its end and holds; leaving shows the cut name again.
private struct MarqueeText: View {
    let text: String
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var natural: CGFloat = 0     // width at the smallest (80 %) size
    @State private var box: CGFloat = 0
    @State private var shift: CGFloat = 0
    private let speed: CGFloat = 32              // points per second: easy reading pace

    var body: some View {
        // At rest the system shrinks (to 80 %) and middle-cuts. A name still cut at 80 % slides at that size.
        let small = Font.system(size: 11.5 * 0.8)
        let overflow = max(0, natural - box)
        let sliding = hovering && overflow > 0.5 && !reduceMotion
        Text(text).font(.system(size: 11.5)).lineLimit(1).minimumScaleFactor(0.8).truncationMode(.middle)
            .opacity(sliding ? 0 : 1)
            .overlay(alignment: .leading) {
                if sliding { Text(text).font(small).fixedSize().offset(x: -shift) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { box = $0 }
            .background(Text(text).font(small).fixedSize().hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { natural = $0 })
            .onChange(of: sliding) { _, on in
                shift = 0
                if on { withAnimation(.linear(duration: Double(overflow / speed)).delay(0.5)) { shift = overflow } }
            }
    }
}

/// Status: what happened, said once, under the divider.
private struct StatusBubble: View {
    struct Content: Equatable {
        var icon: NSImage?
        var symbol: String?
        var text: String
        var dimIcon = false
        var red = false
        @MainActor init?(_ model: AppModel) {
            if model.noAccess {
                symbol = "speaker.slash"; text = String(localized: "No audio access")
            } else if model.saveFailed {
                symbol = "exclamationmark.triangle"; text = String(localized: "The file couldn't be saved"); red = true
            } else if model.echoWarning {
                symbol = "headphones"; text = String(localized: "Mic hears the call. Use headphones."); red = true
            } else if let silence = model.silence {
                // The source is named in the tile above; without it the line fits any name, unscaled.
                symbol = "waveform.slash"
                text = silence == .notYet ? String(localized: "No sound yet") : String(localized: "No sound for 1 min")
            } else if !model.isLive, model.phase != .finished, model.selectionUnavailable, let id = model.selection.appID {
                let app = model.apps.apps[id]
                icon = app?.icon; symbol = app == nil ? "app.dashed" : nil
                // Several apps: their rows above already name them, so the line stays short in every language.
                text = model.selection.appIDs.count > 1 ? String(localized: "The apps aren't open")
                    : app.map { String(localized: "\($0.name) isn't open") } ?? String(localized: "This app isn't open")
                dimIcon = true
            } else if model.phase == .paused {
                // Several apps: the one that came back is named; before that, the line says they all closed.
                let ids = model.selection.appIDs
                let shown = ids.count > 1 && model.targetReopened ? ids.first(where: model.apps.isOpen) : model.selection.appID
                let app = shown.flatMap { model.apps.apps[$0] }
                icon = app?.icon; symbol = app == nil ? "app.dashed" : nil
                if ids.count > 1 && !model.targetReopened {
                    text = String(localized: "The apps closed")
                } else if let name = app?.name {
                    text = model.targetReopened ? String(localized: "\(name) reopened") : String(localized: "\(name) closed")
                } else {
                    text = model.targetReopened ? String(localized: "This app reopened") : String(localized: "This app closed")
                }
                dimIcon = !model.targetReopened
            } else { return nil }
        }
    }
    let content: Content
    var body: some View {
        HStack(spacing: 7) {
            if let icon = content.icon {
                SystemIcon(icon, size: 14)
                    .saturation(content.dimIcon ? 0 : 1).opacity(content.dimIcon ? 0.5 : 1)
            } else if let symbol = content.symbol {
                Image(systemName: symbol).font(.system(size: 11))
            }
            Text(content.text).font(.system(size: 11.5)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(content.red ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(content.red ? Color(nsColor: .systemRed).opacity(0.16) : Color.primary.opacity(0.07)))
        .contrastEdge(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - First launch

private struct Onboarding: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "waveform").font(.system(size: 28, weight: .medium)).padding(.top, 6).padding(.bottom, 14)
            // One line per meaning, ending at a pause; every language is set the same way and measured to fit.
            Text("Records the sound your Mac plays,\nfrom every app or just one.\nYour voice only if you add it.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            Text("macOS asks once for permission.").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.bottom, 18)
            Button("Continue", action: model.continueOnboarding)
                .modifier(GlassButton())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Metric.arc).padding(.top, 8).padding(.bottom, Metric.arc)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Formatting

enum Format {
    static func time(_ s: Double) -> String {
        let t = Int(s), h = t / 3600, m = t / 60 % 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    static func spoken(_ s: Double) -> String {
        Duration.seconds(Int(s)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    /// "Zen - 14-10-2026, 15.32" as "Zen -" and "14-10-2026, 15.32". A name without the dash stays whole.
    static func nameLines(_ name: String) -> (what: String, when: String?) {
        guard let r = name.range(of: " - ", options: .backwards) else { return (name, nil) }
        return (name[..<r.lowerBound] + " -", String(name[r.upperBound...]))
    }
}

extension AppModel {
    func everythingLevel() -> Float { apps.levels.values.max() ?? 0 }
}

extension EnvironmentValues {
    /// The system accent; development renders swap it to show other people's accent colours.
    @Entry var accent: Color = .accentColor
}

/// Increase Contrast: every tile gains a one-pixel edge in the text colour. Nothing changes otherwise.
struct ContrastEdge<S: InsettableShape>: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let shape: S
    func body(content: Content) -> some View {
        content.overlay {
            if model.increasedContrast {
                shape.strokeBorder(Color(nsColor: .textColor).opacity(model.debugEdge ?? 0.22), lineWidth: 1 / scale).allowsHitTesting(false)
            }
        }
    }
}
extension View {
    func contrastEdge(_ shape: some InsettableShape) -> some View { modifier(ContrastEdge(shape: shape)) }
}

/// Liquid Glass where macOS has it (26 and later), the standard prominent button before.
private struct GlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.buttonStyle(.glass) } else { content.buttonStyle(.borderedProminent) }
    }
}

extension View {
    /// The scroll view's vertical offset as it changes. macOS 15 reports it directly; on macOS 14 the
    /// content reports its own position (LegacyOffsetReader) against the scroll view's coordinate space.
    @ViewBuilder func onScrollOffsetChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in action(y) }
        } else {
            coordinateSpace(.named(LegacyOffsetKey.space)).onPreferenceChange(LegacyOffsetKey.self) { action($0) }
        }
    }
}

struct LegacyOffsetKey: PreferenceKey {
    static let space = "scroll-offset"
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Placed behind the scrolled content; only does something on macOS 14.
struct LegacyOffsetReader: View {
    var body: some View {
        if #available(macOS 15, *) {
            Color.clear
        } else {
            GeometryReader { g in
                Color.clear.preference(key: LegacyOffsetKey.self, value: -g.frame(in: .named(LegacyOffsetKey.space)).minY)
            }
        }
    }
}
