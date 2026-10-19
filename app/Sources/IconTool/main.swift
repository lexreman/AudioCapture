import AppKit
import AudioCaptureKit

// Usage: IconTool <out.iconset> [--preview <dir>]
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try AppIcon.png(recording: false, pixels: points * scale)!.write(to: out.appendingPathComponent(name))
}
// The artwork for AppIcon.icon, light and dark, filling the canvas: macOS draws the shape around it.
if args.count > 3, args[2] == "--artwork" {
    let dir = URL(fileURLWithPath: args[3])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try AppIcon.artworkPNG(pixels: 1024, light: true)!.write(to: dir.appendingPathComponent("light.png"))
    try AppIcon.artworkPNG(pixels: 1024, light: false)!.write(to: dir.appendingPathComponent("dark.png"))
}
if args.count > 3, args[2] == "--preview" {
    let dir = URL(fileURLWithPath: args[3])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for rec in [false, true] {
        try AppIcon.png(recording: rec, pixels: 1024)!.write(to: dir.appendingPathComponent(rec ? "icon-recording.png" : "icon.png"))
        try AppIcon.png(recording: rec, pixels: 1024, light: true)!.write(to: dir.appendingPathComponent(rec ? "icon-recording-light.png" : "icon-light.png"))
    }
    // Sheet: real Dock sizes on a dark wallpaper (2x pixels): 128, 64, 32, 16 pt, normal then recording.
    let W = 1200, H = 420
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    NSGradient(starting: NSColor(red: 0.11, green: 0.16, blue: 0.27, alpha: 1), ending: NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)
    var x: CGFloat = 40
    for pt in [128, 64, 32, 16] {
        for rec in [false, true] {
            let s = CGFloat(pt * 2)
            AppIcon.image(recording: rec, points: CGFloat(pt)).draw(in: NSRect(x: x, y: (CGFloat(H) - s) / 2, width: s, height: s))
            x += s + 24
        }
        x += 30
    }
    NSGraphicsContext.restoreGraphicsState()
    try sheet.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("sheet.png"))
}
print("iconset written to \(out.path)")
