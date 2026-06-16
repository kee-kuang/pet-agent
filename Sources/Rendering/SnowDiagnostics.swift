import Foundation

public enum SnowDiagnostics {
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PETAGENT_SNOW_DIAGNOSTICS"] == "1"
    }

    public static func log(_ message: String) {
        guard isEnabled else {
            return
        }

        let line = "[snow] \(message)\n"
        print(line, terminator: "")
        guard let data = line.data(using: .utf8) else {
            return
        }

        let path = "/tmp/petagent-snow-diagnostics.log"
        if FileManager.default.fileExists(atPath: path) == false {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
