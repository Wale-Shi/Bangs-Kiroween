import BangsCore
import Foundation

/// Where Bangs keeps its own data: ~/Library/Application Support/Bangs (or $BANGS_DATA, for tests and trials).
enum Storage {
    static var root: URL {
        custom ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bangs")
    }
    /// Somewhere else to keep it: $BANGS_DATA, or a folder a test sets.
    nonisolated(unsafe) static var custom: URL? = ProcessInfo.processInfo.environment["BANGS_DATA"].map { URL(fileURLWithPath: $0) }

    static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        _ = directory("")
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: root.appendingPathComponent(name), options: [.atomic])
    }

    /// `name` in `directory`, numbered (" 2", " 3"…) when a file of that name is already there: two captures in the same
    /// second, or a copy where one of the same name was saved before.
    static func unique(_ name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = directory.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(number)" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        return url
    }

    /// A file name for a new capture, like macOS names its own screenshots.
    static func stamp(_ prefix: String, ext: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(prefix) \(formatter.string(from: Date())).\(ext)"
    }
}

/// A plain log of what Bangs did, in ~/Library/Application Support/Bangs/bangs.log, for diagnosing problems on someone's Mac.
enum Log {
    /// Where Bangs' data is now (a test moves it after launch).
    private static var url: URL { Storage.root.appendingPathComponent("bangs.log") }
    private static let queue = DispatchQueue(label: "bangs.log")
    static let limit = 1_000_000

    static func write(_ message: String) {
        let line = "\(Timestamps.string()) \(message)\n"
        queue.async {
            _ = Storage.directory("")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
            // Keep it small: past 1 MB it becomes bangs.log.old (replacing the one before) and a new one starts, so what
            // led up to a problem is still there right after the switch.
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > limit {
                let old = url.appendingPathExtension("old")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
        }
    }
}
