import Foundation

// Turns Spotify and Music down while NotchVoice speaks, and back to their own volume afterwards. speak.py does the
// same when the app isn't running. osascript calls block, so they run one at a time on a background queue.
final class MusicDucker: @unchecked Sendable {
    private static let apps = ["Spotify", "Music"]

    private let queue = DispatchQueue(label: "local.notchvoice.music")
    private var saved: [String: Int]?

    func duck(to level: Double) {
        queue.async { [self] in
            guard saved == nil, level < 0.999 else { return }
            var volumes: [String: Int] = [:]
            for app in Self.apps {
                guard let volume = Int(osascript("if application \"\(app)\" is running then tell application \"\(app)\" to get sound volume")) else { continue }
                volumes[app] = volume
                setVolume(app, Int((Double(volume) * level).rounded()))
            }
            saved = volumes
        }
    }

    func restore() {
        queue.async { [self] in
            guard let volumes = saved else { return }
            saved = nil
            for (app, volume) in volumes { setVolume(app, volume) }
        }
    }

    private func setVolume(_ app: String, _ volume: Int) {
        // "is running" never launches the app.
        _ = osascript("if application \"\(app)\" is running then tell application \"\(app)\" to set sound volume to \(volume)")
    }

    private func osascript(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
