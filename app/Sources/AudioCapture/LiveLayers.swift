import AppKit
import QuartzCore
import SwiftUI

/// One display link for every moving thing in the window (measured: CALayer + display link
/// costs 1–2 % CPU where SwiftUI TimelineView + Canvas cost 9 %). Paused while the window is hidden.
@MainActor final class Ticker: NSObject {
    static let shared = Ticker()
    private var link: CADisplayLink?
    private var subscribers: [ObjectIdentifier: (Double) -> Void] = [:]
    private var last: CFTimeInterval = 0
    var paused = false { didSet { link?.isPaused = paused || subscribers.isEmpty } }

    func attach(to view: NSView) {
        guard link == nil else { return }
        link = view.displayLink(target: self, selector: #selector(step(_:)))
        link?.add(to: .main, forMode: .common)
        link?.isPaused = paused || subscribers.isEmpty
    }
    func subscribe(_ owner: AnyObject, _ body: @escaping (Double) -> Void) {
        subscribers[ObjectIdentifier(owner)] = body
        link?.isPaused = paused
    }
    func unsubscribe(_ owner: AnyObject) {
        subscribers[ObjectIdentifier(owner)] = nil
        if subscribers.isEmpty { link?.isPaused = true }
    }
    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last == 0 ? 1.0 / 60 : min(0.1, now - last)   // decay by time, not frame count (display may run at 75 Hz)
        last = now
        for body in subscribers.values { body(dt) }
    }
}

/// Three bars that follow an app's real level, on a decibel scale.
final class MarkNSView: NSView {
    /// Bars reach 11 pt; the box is 12 so it centres in the 34 pt row on whole points (11 would sit at y 11.5).
    static let size = CGSize(width: 12, height: 12)
    var level: () -> Float = { 0 }
    private var bars: [CALayer] = []
    private var shown: Float = 0
    private var phase: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for i in 0..<3 {
            let bar = CALayer()
            bar.cornerRadius = 1
            bar.frame = CGRect(x: CGFloat(i) * 5, y: 0, width: 2, height: 2)
            layer?.addSublayer(bar); bars.append(bar)
        }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func viewDidChangeEffectiveAppearance() { updateColors() }
    private func updateColors() { effectiveAppearance.performAsCurrentDrawingAppearance { bars.forEach { $0.backgroundColor = NSColor.labelColor.cgColor } } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Ticker.shared.subscribe(self) { [weak self] dt in self?.step(dt) } } else { Ticker.shared.unsubscribe(self) }
    }

    private func step(_ dt: Double) {
        // Decibels, not raw amplitude: −60 dBFS (the "playing" threshold the list ranks by) to 0 dBFS.
        // A quiet app (its own volume low) still shows small marks instead of none.
        let peak = level()
        let v = peak > 0.001 ? min(1, (20 * log10(peak) + 60) / 60) : 0
        shown = max(v, shown - Float(dt) * 3)
        phase += dt
        let on = shown > 0.01
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            // With Reduce Motion the bars follow the level only, without their own wobble.
            let wobble = reduceMotion ? 1 : 0.6 + 0.4 * abs(sin(phase * (5 + Double(i) * 2.3) + Double(i)))
            let h = on ? 2 + 9 * min(1, CGFloat(Double(shown) * wobble)) : 2
            bar.frame = CGRect(x: CGFloat(i) * 5, y: 0, width: 2, height: pixel(h))   // 2 pt bars, 3 pt gaps: whole pixels, last edge on the box
            bar.opacity = on ? 1 : 0
        }
        CATransaction.commit()
    }
}

struct MarkView: NSViewRepresentable {
    let level: () -> Float
    func makeNSView(context: Context) -> MarkNSView { let v = MarkNSView(frame: NSRect(origin: .zero, size: MarkNSView.size)); v.level = level; return v }
    func updateNSView(_ v: MarkNSView, context: Context) { v.level = level }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkNSView, context: Context) -> CGSize? { MarkNSView.size }
}

extension NSView {
    /// A length rounded to whole device pixels (1 pt at 1x, 0.5 pt at 2x), so live layer edges stay crisp.
    func pixel(_ v: CGFloat) -> CGFloat {
        let s = window?.backingScaleFactor ?? 2
        return (v * s).rounded() / s
    }
}

/// The microphone badge's glyph while your voice is part of the recording: brightens with your voice
/// (decibel scale, like the level marks), dims while the app isn't using the mic, slashed when cut.
final class VoiceNSView: NSView {
    enum State { case live, idle, cut }
    var level: () -> Float = { 0 }
    var state: State = .live { didSet { if state != oldValue { refresh() } } }
    private let glyph = CALayer()
    private var shown: Float = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glyph.contentsGravity = .center
        layer?.addSublayer(glyph)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // the SwiftUI button around it takes the click
    override func layout() { super.layout(); glyph.frame = bounds }
    override func viewDidChangeEffectiveAppearance() { refresh() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
        if window != nil { Ticker.shared.subscribe(self) { [weak self] dt in self?.step(dt) } } else { Ticker.shared.unsubscribe(self) }
    }

    private func refresh() {
        let color = NSColor.white                       // drawn on the graphite microphone badge
        let config = NSImage.SymbolConfiguration(pointSize: 6, weight: .bold).applying(.init(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: state == .cut ? "mic.slash.fill" : "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        // Drawn into a bitmap at the window's own scale, so the glyph keeps its size at any resolution
        // (handing the layer the NSImage lets it pick a representation that may not match its scale).
        let scale = window?.backingScaleFactor ?? 2
        glyph.contents = symbol.flatMap { image in
            let rect = NSRect(origin: .zero, size: image.size)
            let pixels = NSSize(width: ceil(image.size.width * scale), height: ceil(image.size.height * scale))
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }
        glyph.contentsScale = scale
        step(0)
    }

    private func step(_ dt: Double) {
        let peak = state == .live ? level() : 0
        let v = peak > 0.001 ? min(1, (20 * log10(peak) + 60) / 60) : 0
        shown = max(v, shown - Float(dt) * 3)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.opacity = switch state { case .live: 0.45 + 0.55 * shown; case .idle: 0.3; case .cut: 0.85 }
        CATransaction.commit()
    }
}

struct VoiceGlyph: NSViewRepresentable {
    let state: VoiceNSView.State
    let level: () -> Float
    func makeNSView(context: Context) -> VoiceNSView { let v = VoiceNSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)); update(v); return v }
    func updateNSView(_ v: VoiceNSView, context: Context) { update(v) }
    private func update(_ v: VoiceNSView) { v.level = level; v.state = state }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: VoiceNSView, context: Context) -> CGSize? { CGSize(width: 10, height: 10) }
}

/// 28-band spectrum that *is* the tile: the tile colour is drawn with the bars cut out of it, so the
/// window's own background shows through each bar (exactly its grey, whatever the tile colour).
/// Bars stand on the tile's bottom edge; fast attack, timed fall, slow-falling peak caps (also cut out).
/// Clipping fills the holes red.
final class SpectrumNSView: NSView {
    var source: () -> (bands: [Float], clipped: Bool) = { ([], false) }
    var tile: NSColor = .clear
    private let plate = CAShapeLayer()
    private var clips: [CALayer] = []
    private var values = [Float](repeating: 0, count: 28), capValues = [Float](repeating: 0, count: 28)
    private var clipHold: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plate.fillRule = .evenOdd
        layer?.addSublayer(plate)
        for _ in 0..<28 { let c = CALayer(); layer?.addSublayer(c); clips.append(c) }
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(String(localized: "Sound level"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Ticker.shared.subscribe(self) { [weak self] dt in self?.step(dt) } } else { Ticker.shared.unsubscribe(self) }
    }

    /// Development renders only: draw now, without waiting for the display link.
    func renderForCapture() { for _ in 0..<40 { step(1.0 / 60) } }

    private func step(_ dt: Double) {
        let (fresh, clipped) = source()
        if clipped { clipHold = 0.3 } else { clipHold = max(0, clipHold - dt) }
        let w = bounds.width, h = bounds.height, n = 28, gap: CGFloat = 2
        let bw = (w - gap * CGFloat(n - 1)) / CGFloat(n), pitch = bw + gap
        // 264 pt full bleed gives 7.5 pt bars: at 1x every edge is rounded to a whole pixel, so the
        // 2 pt gaps stay exact and bars alternate 8 and 7 px instead of blurring; at 2x nothing moves.
        var fill = NSColor.clear.cgColor, red = NSColor.systemRed.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = tile.cgColor
            red = NSColor.systemRed.withAlphaComponent(0.7).cgColor
        }
        let path = CGMutablePath()
        path.addRect(bounds)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in 0..<n {
            let v = i < fresh.count ? fresh[i] : 0
            values[i] = max(v, values[i] - Float(dt) * 2.2)
            capValues[i] = max(values[i], capValues[i] - Float(dt) * 0.45)
            let x = pixel(CGFloat(i) * pitch), right = pixel(CGFloat(i) * pitch + bw)
            let bar = CGRect(x: x, y: 0, width: right - x, height: max(1, pixel(CGFloat(values[i]) * h)))
            path.addRect(bar)
            // A cap only where it stands clear of its bar (overlapping holes would refill under even-odd).
            let capY = pixel(CGFloat(capValues[i]) * h) - 1
            if capValues[i] > 0.04 && capY >= bar.maxY + 1 { path.addRect(CGRect(x: x, y: capY, width: bar.width, height: 1)) }
            clips[i].frame = bar
            clips[i].backgroundColor = red
            clips[i].opacity = clipHold > 0 ? 1 : 0
        }
        plate.frame = bounds
        plate.path = path
        plate.fillColor = fill
        CATransaction.commit()
        let avg = values.reduce(0, +) / Float(n)
        setAccessibilityValue(avg > 0.02 ? String(localized: "\(Int(-72 + avg * 72)) dB") : String(localized: "Silent"))
    }
}

struct SpectrumView: NSViewRepresentable {
    let tile: NSColor
    let source: () -> (bands: [Float], clipped: Bool)
    func makeNSView(context: Context) -> SpectrumNSView { let v = SpectrumNSView(frame: .zero); v.source = source; v.tile = tile; return v }
    func updateNSView(_ v: SpectrumNSView, context: Context) { v.source = source; v.tile = tile }
}

/// Click to reveal, drag to hand over the real file URL (copy only), hover reported to SwiftUI.
final class FileDragNSView: NSView, NSDraggingSource {
    var url: URL?
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    private var downAt: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { if downAt != nil { onClick() }; downAt = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, let url, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct FileDrag: NSViewRepresentable {
    let url: URL
    let tip: String          // shown on hover after the system delay; SwiftUI's .help can't reach through this view
    let onClick: () -> Void
    let onHover: (Bool) -> Void
    func makeNSView(context: Context) -> FileDragNSView { let v = FileDragNSView(); update(v); return v }
    func updateNSView(_ v: FileDragNSView, context: Context) { update(v) }
    private func update(_ v: FileDragNSView) { v.url = url; v.toolTip = tip; v.onClick = onClick; v.onHover = onHover }
}

/// Reads the window's concentric corner radius at a given inset (measured 16 − inset on macOS 27).
/// Older macOS can't report it: AppDelegate falls back to the window radius minus the inset.
@available(macOS 27, *)
final class ConcentricProbe: NSView {
    override var cornerConfiguration: NSViewCornerConfiguration? { .uniformCorners(radius: .containerConcentric) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // invisible measuring view: never takes a click
    var onRadius: (CGFloat) -> Void = { _ in }
    override func viewDidChangeEffectiveCornerRadii() {
        super.viewDidChangeEffectiveCornerRadii()
        if let r = effectiveCornerRadii?.bottomLeft, r > 0 { onRadius(r) }
    }
}
