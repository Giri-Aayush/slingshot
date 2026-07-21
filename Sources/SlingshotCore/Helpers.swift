import AppKit

// MARK: - Helpers

public let logFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Slingshot.log")
public let shotsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Pictures/Slingshot", isDirectory: true)

let logQueue = DispatchQueue(label: "slingshot.log")
let logFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    return df
}()
let logHandle: FileHandle? = {
    let fm = FileManager.default
    // Rotate at 5 MB, keeping one previous generation.
    if let size = (try? fm.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int, size > 5_000_000 {
        let old = logFileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logFileURL, to: old)
    }
    if !fm.fileExists(atPath: logFileURL.path) {
        fm.createFile(atPath: logFileURL.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: logFileURL)
    handle?.seekToEndOfFile()
    return handle
}()

public func log(_ msg: String) {
    let now = Date()
    logQueue.async {
        let line = "[\(logFormatter.string(from: now))] \(msg)\n"
        print(line, terminator: "")
        fflush(stdout)
        if let data = line.data(using: .utf8) {
            logHandle?.write(data)
        }
    }
}

public func play(_ name: String) {
    NSSound(named: NSSound.Name(name))?.play()
}

/// Stable per-install identity used for peer trust; peer display names carry a
/// random suffix each launch, so trust must key on something durable.
public let installID: String = {
    let defaults = UserDefaults.standard
    if let id = defaults.string(forKey: "installID") { return id }
    let id = UUID().uuidString
    defaults.set(id, forKey: "installID")
    return id
}()

public func cleanName(_ s: String) -> String {
    s.components(separatedBy: "#").first ?? s
}

public struct RuntimeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

