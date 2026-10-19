import AppKit
import Accelerate
import SwiftUI
import UniformTypeIdentifiers

/// An app, folder or file icon as the Dock draws it: in the icon style chosen in System Settings
/// (Default, Dark, Clear or Tinted). SwiftUI's Image(nsImage:) falls back to the default variant
/// (measured with the Dark style: an icon drawn at brightness 0.35 there, 0.09 by AppKit), so the
/// icon is drawn by AppKit and redrawn when the style changes. Small sizes are no help either: macOS
/// themes only the large variants of many icons (some stay light at 32 px and below, dark from 40 px),
/// so every icon is drawn large, as the Dock shows it, and scaled down here.
struct SystemIcon: View {
    private let source: IconStyle.Source
    let size: CGFloat
    @Environment(\.displayScale) private var scale
    private var style = IconStyle.shared

    init(_ image: NSImage, size: CGFloat) { source = .image(image); self.size = size }
    /// A file or folder's icon, looked up once per path. A path that isn't there (a folder on an unplugged
    /// drive, a file moved away) shows the generic icon of its kind, never a blank page.
    init(path: String, size: CGFloat, kind: UTType = .folder) { source = .path(path, kind); self.size = size }

    var body: some View {
        let pixels = Int((size * scale).rounded())
        if let cg = style.render(source, pixels: pixels) {
            Image(decorative: cg, scale: scale).frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// Follows the system icon style and draws icons in it, cached per image, size and style.
@MainActor @Observable
final class IconStyle: NSObject {
    static let shared = IconStyle()
    private(set) var version = 0
    @ObservationIgnored private var cache: [Key: (image: NSImage, cg: CGImage?)] = [:]
    @ObservationIgnored private var appearanceWatch: NSKeyValueObservation?
    @ObservationIgnored private var activeWatch: NSObjectProtocol?
    @ObservationIgnored private var lastSeen = ""

    private static func snapshot() -> String {
        keys.map { UserDefaults.standard.string(forKey: $0) ?? "-" }.joined(separator: "|")
            + "|" + (NSApp?.effectiveAppearance.name.rawValue ?? "")
    }
    enum Source { case image(NSImage), path(String, UTType) }
    private struct Key: Hashable { let id: String; let pixels: Int; let version: Int }
    private static let keys = ["AppleIconAppearanceTheme", "AppleIconAppearanceTintColor", "AppleInterfaceStyle"]

    override private init() {
        super.init()
        // Another process changes these (System Settings), and UserDefaults reports such changes by KVO.
        for key in Self.keys { UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil) }
        // A backstop if a change slips past KVO: compare the settings whenever the app comes forward.
        lastSeen = Self.snapshot()
        activeWatch = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.snapshot() != self.lastSeen else { return }
                self.changed()
            }
        }
        // "Automatic" styles follow light and dark.
        appearanceWatch = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.changed() }
        }
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.changed() }
    }

    /// Posted when the icon style or appearance changes, for drawings outside SwiftUI (the Dock icon).
    static let didChange = Notification.Name("io.github.lexreman.audiocapture.iconStyleDidChange")

    private func changed() {
        lastSeen = Self.snapshot()
        cache.removeAll()
        version += 1
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func render(_ source: Source, pixels: Int) -> CGImage? {
        let id: String
        switch source {
        case .image(let image): id = "i\(ObjectIdentifier(image).hashValue)"
        case .path(let path, _): id = (FileManager.default.fileExists(atPath: path) ? "p" : "m") + path
        }
        let key = Key(id: id, pixels: pixels, version: version)
        // The cached entry holds its image, so an identity can't be reused by another image while cached.
        if let hit = cache[key] {
            if case .image(let image) = source, hit.image !== image {} else { return hit.cg }
        }
        let image: NSImage
        switch source {
        case .image(let i): image = i
        case .path(let path, let kind):
            image = FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: kind)
        }
        guard pixels > 0, let large = draw(image, pixels: max(Self.themedSize, pixels)) else { return nil }
        let cg = pixels == large.width ? large : Self.scale(large, to: pixels)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = (image, cg)
        return cg
    }

    /// Large enough that macOS draws the icon in the user's style.
    private static let themedSize = 128

    private func draw(_ image: NSImage, pixels: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        (NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Lanczos downscale (vImage high-quality resampling) in premultiplied RGBA.
    private static func scale(_ image: CGImage, to pixels: Int) -> CGImage? {
        guard let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
              var source = try? vImage_Buffer(cgImage: image, format: format),
              var target = try? vImage_Buffer(width: pixels, height: pixels, bitsPerPixel: 32) else { return nil }
        defer { source.free(); target.free() }
        guard vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return nil }
        return try? target.createCGImage(format: format)
    }
}
