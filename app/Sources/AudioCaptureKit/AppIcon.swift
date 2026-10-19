import AppKit

/// The app icon, drawn in code so the bundle icon and the runtime recording
/// variant come from one source: a sound wave held in a clear bubble on a
/// graphite tile. Recording turns the wave red and tints the bubble.
public enum AppIcon {
    public static func image(recording: Bool, points: CGFloat = 512, light: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points))
        for scale in [1, 2] {
            if let rep = bitmap(recording: recording, pixels: Int(points) * scale, light: light) {
                rep.size = image.size
                image.addRepresentation(rep)
            }
        }
        return image
    }

    public static func png(recording: Bool, pixels: Int, light: Bool = false) -> Data? {
        bitmap(recording: recording, pixels: pixels, light: light)?.representation(using: .png, properties: [:])
    }

    /// The artwork alone, filling the whole canvas, for the system icon (AppIcon.icon): macOS draws
    /// the shape, its edge and its shadow around it, in the light or dark version the icon style asks for.
    public static func artworkPNG(pixels: Int, light: Bool) -> Data? {
        bitmap(recording: false, pixels: pixels, light: light, artwork: true)?.representation(using: .png, properties: [:])
    }

    static func bitmap(recording: Bool, pixels: Int, light: Bool = false, artwork: Bool = false) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ns = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = ns.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        // Work in a 1024 canvas with a top-left origin, like the design drawings.
        cg.translateBy(x: 0, y: CGFloat(pixels))
        cg.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
        if artwork {
            // The 824-point body grows to fill the canvas.
            cg.translateBy(x: 512, y: 512); cg.scaleBy(x: 1024 / 824, y: 1024 / 824); cg.translateBy(x: -512, y: -512)
        }
        draw(in: cg, recording: recording, scale: CGFloat(pixels) / 1024, light: light, artwork: artwork)
        return rep
    }

    // MARK: Drawing

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    private static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    }

    /// Continuous-corner body: superellipse (n = 5) on Apple's 824-point body inside the 1024 canvas.
    static func squircle(center: CGPoint, half: CGFloat, n: CGFloat = 5) -> CGPath {
        let p = CGMutablePath()
        for i in 0...240 {
            let t = CGFloat(i) / 240 * 2 * .pi, co = cos(t), si = sin(t)
            let x = center.x + half * (co < 0 ? -1 : 1) * pow(abs(co), 2 / n)
            let y = center.y + half * (si < 0 ? -1 : 1) * pow(abs(si), 2 / n)
            i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
        }
        p.closeSubpath()
        return p
    }

    // MARK: Geometry: a sound wave that enters and leaves the frame, magnified where it passes through the bubble

    static let bubbleCenter = CGPoint(x: 512, y: 512)
    static let bubbleRadius: CGFloat = 292
    static let magnification: CGFloat = 1.45          // < 1.5 keeps the lens mapping monotonic to the rim

    /// A sound crossing the whole tile, alive like speech or music: bursts of different strength
    /// and pace with near-quiet pauses between them, loudest where the bubble holds it.
    static let bursts: [(center: CGFloat, height: CGFloat, width: CGFloat)] = [
        (60, 14, 34), (160, 18, 34),                       // outside, quiet
        (385, 26, 30), (500, 58, 50), (640, 34, 34),       // inside, away from the rim, where the lens squeezes the line
        (880, 18, 32), (990, 12, 32),                      // outside, quiet
    ]
    static func amplitude(_ x: CGFloat) -> CGFloat {
        1.5 + bursts.reduce(0) { $0 + $1.height * exp(-pow((x - $1.center) / $1.width, 2)) }
    }
    /// Phase with a pace that drifts, so no two cycles are the same length.
    static func phase(_ x: CGFloat) -> CGFloat {
        let wavelength: CGFloat = 64, drift: CGFloat = 0.22
        return 2 * .pi * (x / wavelength + drift * 170 / wavelength * sin(x / 170) / (2 * .pi))
    }
    static func baseY(_ x: CGFloat) -> CGFloat { 512 - amplitude(x) * sin(phase(x)) }

    /// The same wave seen through a glass sphere: radial magnification M at the centre falling
    /// smoothly to 1 at the rim, so the line is continuous where it enters and leaves the bubble.
    static func lensed(_ p: CGPoint) -> CGPoint {
        let dx = p.x - bubbleCenter.x, dy = p.y - bubbleCenter.y, r = hypot(dx, dy), R = bubbleRadius
        guard r < R else { return p }
        let g = magnification - (magnification - 1) * (r * r) / (R * R)
        return CGPoint(x: bubbleCenter.x + dx * g, y: bubbleCenter.y + dy * g)
    }

    /// One smooth curve (Catmull-Rom through lensed samples), not hundreds of tiny segments:
    /// dense polylines leave hairline seams where Core Graphics joins them.
    static func wavePath() -> CGPath {
        let pts = (0...420).map { i -> CGPoint in
            let x = -40 + CGFloat(i) / 420 * 1104
            return lensed(CGPoint(x: x, y: baseY(x)))
        }
        let p = CGMutablePath()
        p.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            p.addCurve(to: p2,
                       control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return p
    }

    private static func strokeWithGradient(_ cg: CGContext, path: CGPath, width: CGFloat, gradient g: CGGradient, from: CGPoint, to: CGPoint) {
        cg.saveGState()
        cg.addPath(path); cg.setLineWidth(width); cg.setLineCap(.round); cg.setLineJoin(.round)
        cg.replacePathWithStrokedPath(); cg.clip()
        cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

    private static func draw(in cg: CGContext, recording rec: Bool, scale: CGFloat, light: Bool, artwork: Bool = false) {
        let body = artwork ? CGPath(rect: CGRect(x: 100, y: 100, width: 824, height: 824), transform: nil)
                           : squircle(center: CGPoint(x: 512, y: 512), half: 412)
        let C = bubbleCenter, R = bubbleRadius
        let wave = wavePath()

        // Tile: near-black in the dark version, neutral like the system's own dark icons; one soft shadow.
        cg.saveGState()
        if !artwork { cg.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: c(0x000000, light ? 0.28 : 0.45)) }
        cg.addPath(body); cg.setFillColor(c(light ? 0xe9e9ec : 0x161617)); cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(body); cg.clip()
        cg.drawLinearGradient(light ? gradient([(0, c(0xffffff)), (0.5, c(0xf0f0f2)), (1, c(0xdcdce0))])
                                    : gradient([(0, c(0x262627)), (0.5, c(0x171718)), (1, c(0x111112))]),
                              start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

        // The passing sound: thin and quiet, running out of both edges of the tile.
        cg.saveGState()
        cg.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024)); cg.addEllipse(in: circle(C, R)); cg.clip(using: .evenOdd)
        cg.addPath(wave); cg.setLineWidth(13); cg.setLineCap(.butt); cg.setLineJoin(.round)
        cg.setStrokeColor(light ? c(0x1d1d1f, 0.26) : c(0xffffff, 0.34)); cg.strokePath()
        cg.restoreGState()

        // Inside the bubble: the captured sound, magnified, solid.
        cg.saveGState()
        cg.addEllipse(in: circle(C, R)); cg.clip()
        cg.drawLinearGradient(light ? gradient([(0, c(0xd6d6db)), (1, c(0xfbfbfc))])
                                    : gradient([(0, c(0x141415)), (1, c(0x2d2d2f))]),
                              start: CGPoint(x: C.x, y: C.y - R), end: CGPoint(x: C.x, y: C.y + R), options: [])
        cg.drawRadialGradient(gradient([(0, c(rec ? 0xff453a : 0xffffff, rec ? 0.07 : 0.02)), (0.8, c(0xffffff, 0.035)), (1, c(0xffffff, 0.13))]),
                              startCenter: C, startRadius: 0, endCenter: C, endRadius: R, options: [])
        if rec {
            strokeWithGradient(cg, path: wave, width: 24, gradient: gradient([(0, c(0xff7066)), (1, c(0xe8291e))]),
                               from: CGPoint(x: 512, y: 380), to: CGPoint(x: 512, y: 650))
        } else {
            cg.addPath(wave); cg.setLineWidth(24); cg.setLineJoin(.round); cg.setStrokeColor(c(light ? 0x2a2b2f : 0xf5f6f8)); cg.strokePath()
        }
        cg.restoreGState()

        // Thin-film colour on the rim: the one thing that says "bubble", kept faint.
        cg.saveGState()
        let band = CGMutablePath(); band.addEllipse(in: circle(C, R)); band.addEllipse(in: circle(C, R - 10))
        cg.addPath(band); cg.clip(using: .evenOdd)
        let film = rec ? [c(0xff8a70, 0.30), c(0xff453a, 0.12), c(0xffb36b, 0.26), c(0xff6a5a, 0.10), c(0xff8a70, 0.30)]
                       : [c(0xc7a8ff, 0.30), c(0x8fe3ff, 0.14), c(0xffe0a3, 0.26), c(0xff9ed2, 0.12), c(0xc7a8ff, 0.30)]
        let conic = CGGradient(colorsSpace: space, colors: film as CFArray, locations: [0, 0.25, 0.5, 0.75, 1])!
        CGContextDrawConicGradient(cg, conic, C, .pi / 5)
        cg.restoreGState()

        // Rim: one crisp hairline.
        cg.addEllipse(in: circle(C, R - 0.75)); cg.setLineWidth(2.5); cg.setStrokeColor(light ? c(0x000000, 0.16) : c(0xffffff, 0.5)); cg.strokePath()

        // Highlight: a single crescent along the upper left, fading toward the middle.
        cg.saveGState()
        let crescent = CGMutablePath()
        crescent.addEllipse(in: circle(C, R - 14))
        crescent.addEllipse(in: circle(CGPoint(x: C.x + 16, y: C.y + 20), R - 14))
        cg.addPath(crescent); cg.clip(using: .evenOdd)
        cg.addEllipse(in: circle(C, R - 14)); cg.clip()
        cg.drawLinearGradient(gradient([(0, c(0xffffff, 0.75)), (0.4, c(0xffffff, 0.16)), (0.62, c(0xffffff, 0))]),
                              start: CGPoint(x: C.x - R * 0.7, y: C.y - R * 0.7), end: C, options: [])
        cg.restoreGState()

        cg.restoreGState()   // tile clip

        // Tile edge: a fine highlight, brighter at the top.
        if artwork { return }
        strokeWithGradient(cg, path: body, width: 4,
                           gradient: light ? gradient([(0, c(0xffffff, 0.9)), (0.25, c(0xffffff, 0.3)), (1, c(0x000000, 0.08))])
                                           : gradient([(0, c(0xffffff, 0.42)), (0.25, c(0xffffff, 0.07)), (1, c(0xffffff, 0.14))]),
                           from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    }
}
