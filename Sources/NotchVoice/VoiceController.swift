import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "voice")

@MainActor
final class VoiceController: ObservableObject {
    static let baseRate = 180.0

    @Published private(set) var isEnabled = true
    @Published private(set) var voiceID: String?
    @Published private(set) var voiceName = "System Voice"
    @Published private(set) var systemVoiceLabel = "System Voice"
    @Published private(set) var speed = 1.0
    @Published private(set) var musicVolume = 0.5
    @Published private(set) var keepsRepliesShort = true

    // Speaks a voice sample. SpeechCenter sets this, because it owns the speaker.
    var speak: (String) -> Void = { _ in }

    // The contract of ~/.claude/hooks/speak.py, which speaks by itself when the app isn't running: it stays silent
    // while the mute file exists, and takes its voice, rate and music level from the settings file.
    private let muteFile = URL.homeDirectory.appending(path: ".claude/tts_off")
    private let settingsFile = URL.homeDirectory.appending(path: ".claude/tts_settings.json")

    init() {
        loadSettings()
        refresh()
    }

    // The same voice and rate options speak.py passes to `say`.
    var sayArguments: [String] {
        var arguments: [String] = []
        if let voiceID { arguments += ["-v", voiceID] }
        if abs(speed - 1) > 0.01 { arguments += ["-r", String(Int((Self.baseRate * speed).rounded()))] }
        return arguments
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            try? FileManager.default.removeItem(at: muteFile)
        } else {
            FileManager.default.createFile(atPath: muteFile.path, contents: nil)
        }
        refresh()
    }

    func setVoice(_ id: String?) {
        voiceID = id
        voiceName = id.flatMap(VoiceCatalog.displayName(of:)) ?? systemVoiceLabel
        saveSettings()
        playSample()
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        saveSettings()
    }

    func setMusicVolume(_ volume: Double) {
        musicVolume = volume
        saveSettings()
    }

    func setKeepsRepliesShort(_ enabled: Bool) {
        keepsRepliesShort = enabled
        saveSettings()
    }

    func loadSettings() {
        let settings = (try? Data(contentsOf: settingsFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let id = (settings["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        systemVoiceLabel = VoiceCatalog.systemVoiceLabel
        voiceID = id
        voiceName = id.flatMap(VoiceCatalog.displayName(of:)) ?? systemVoiceLabel
        speed = (settings["rate"] as? Double).map { ($0 / Self.baseRate * 10).rounded() / 10 } ?? 1
        musicVolume = settings["duck"] as? Double ?? 0.5
        keepsRepliesShort = settings["brief"] as? Bool ?? true
    }

    func playSample() {
        let name = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0)?.name }
        speak((name.map { "Hi, I'm \($0). " } ?? "Hi! ") + "This is how Claude's replies will sound.")
    }

    func refresh() {
        let enabled = !FileManager.default.fileExists(atPath: muteFile.path)
        if isEnabled != enabled { isEnabled = enabled }
    }

    private func saveSettings() {
        var settings: [String: Any] = ["duck": NSDecimalNumber(string: String(format: "%.2f", musicVolume)), "brief": keepsRepliesShort]
        if let voiceID { settings["voice"] = voiceID }
        if abs(speed - 1) > 0.01 { settings["rate"] = Int((Self.baseRate * speed).rounded()) }
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: settingsFile, options: .atomic)
        } catch {
            log.error("could not save settings: \(error.localizedDescription)")
        }
    }
}
