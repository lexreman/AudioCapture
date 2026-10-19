import AppKit
import AVFoundation
import AudioCaptureKit

/// A finished recording on disk.
struct Capture: Equatable {
    var url: URL
    var duration: Double
    var bytes: Int64
    var recovered = false
    var note: String?            // "Saved at sleep", "Stopped, disk almost full", "Stopped, write error"
    var sourceApp: String?       // bundle id of the recorded app; nil for Everything (and recovered files)
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// A recording whose file isn't final yet: where it was written, its final path, and a bookmark to it.
struct Pending: Codable, Equatable {
    var hidden: String
    var final: String
    var bookmark: Data?
}

enum Files {
    /// "Safari - 14-10-2026, 15.32": day-month-year, then the time as the Mac shows it (12- or 24-hour,
    /// as set in System Settings) with "." for ":", as in screenshot names. File names can't hold ":" or "/".
    static func baseName(source: String, date: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "dd-MM-yyyy"
        let time = DateFormatter()
        time.locale = .autoupdatingCurrent
        time.setLocalizedDateFormatFromTemplate("jmm")
        let clock = time.string(from: date).replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")   // a plain space before PM
        let clean = source.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let safe = clean.hasPrefix(".") ? "-" + clean.dropFirst() : Substring(clean)
        return "\(safe) - \(day.string(from: date)), \(clock)"
    }

    /// First free "name.ext", then "name 2.ext", "name 3.ext" …
    static func unique(_ base: String, ext: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: hidden(url).path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
        }
        return url
    }

    /// While recording the file is hidden next to its final place; stopping is an instant rename.
    static func hidden(_ final: URL) -> URL { final.deletingLastPathComponent().appendingPathComponent("." + final.lastPathComponent) }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func freeBytes(_ folder: URL) -> Int64 {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    static func publish(hidden: URL, as final: URL) throws -> URL {
        var target = final
        if FileManager.default.fileExists(atPath: target.path) {
            target = unique(final.deletingPathExtension().lastPathComponent, ext: final.pathExtension, in: final.deletingLastPathComponent())
        }
        try FileManager.default.moveItem(at: hidden, to: target)
        return target
    }

    /// A bookmark follows the file if its folder is renamed or moved, or its drive is unplugged and back.
    static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where a pending recording's hidden file is now: through its bookmark, else its path. Nil when it
    /// can't be reached. Never mounts anything (a network drive would make launch wait).
    /// Only the hidden file counts: once published, the bookmark follows the file to its final name,
    /// and a published file is never moved again.
    static func locate(_ p: Pending) -> URL? {
        if let data = p.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               url.lastPathComponent == URL(fileURLWithPath: p.hidden).lastPathComponent,
               FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.fileExists(atPath: p.hidden) ? URL(fileURLWithPath: p.hidden) : nil
    }

    /// The file is on a drive that isn't connected now. The bookmark knows which drive it was (two sticks
    /// can share a name, and a folder can reach a drive through a link); without one, the path says.
    static func onMissingVolume(_ p: Pending) -> Bool {
        if let data = p.bookmark,
           let drive = URL.resourceValues(forKeys: [.volumeUUIDStringKey], fromBookmarkData: data)?.volumeUUIDString {
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
            return !mounted.contains { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString == drive }
        }
        let parts = URL(fileURLWithPath: p.hidden).pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }

    /// Publishes a hidden file in the folder it is in now (it may have been renamed or moved), under its final name.
    static func publish(located hidden: URL, finalName: String) throws -> URL {
        try publish(hidden: hidden, as: hidden.deletingLastPathComponent().appendingPathComponent(finalName))
    }

    static func duration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func displayName(_ folder: URL) -> String { FileManager.default.displayName(atPath: folder.path) }
}
