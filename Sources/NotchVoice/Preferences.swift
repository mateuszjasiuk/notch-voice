import Foundation

enum ReadingMode: String, CaseIterable, Identifiable {
    case autoRead = "auto"
    case announceOnly = "announce"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoRead: "Read them aloud"
        case .announceOnly: "Only say who replied"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private static let themeKey = "glowTheme"
    private static let muteShortcutKey = "muteShortcut"
    private static let permissionsKey = "asksForPermissionInNotch"
    private static let readingModeKey = "readingMode"

    @Published private(set) var theme: GlowTheme
    @Published private(set) var opensAtLogin: Bool
    @Published private(set) var muteShortcut: Shortcut?
    @Published private(set) var asksForPermission: Bool
    @Published private(set) var readingMode: ReadingMode
    private let muteHotkey: Hotkey

    init(muteHotkey: Hotkey) {
        theme = UserDefaults.standard.string(forKey: Self.themeKey).flatMap(GlowTheme.init(rawValue:)) ?? .aurora
        opensAtLogin = LoginItem.isEnabled
        asksForPermission = UserDefaults.standard.object(forKey: Self.permissionsKey) as? Bool ?? true
        readingMode = UserDefaults.standard.string(forKey: Self.readingModeKey).flatMap(ReadingMode.init(rawValue:)) ?? .autoRead
        self.muteHotkey = muteHotkey
        muteShortcut = Self.savedMuteShortcut.flatMap { muteHotkey.register($0) ? $0 : nil }
    }

    func setTheme(_ theme: GlowTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
    }

    func setAsksForPermission(_ enabled: Bool) {
        asksForPermission = enabled
        UserDefaults.standard.set(enabled, forKey: Self.permissionsKey)
    }

    func setReadingMode(_ mode: ReadingMode) {
        readingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.readingModeKey)
    }

    func setOpensAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        refresh()
    }

    func setMuteShortcut(_ shortcut: Shortcut?) -> Bool {
        guard muteHotkey.register(shortcut) else { return false }
        muteShortcut = shortcut
        if let shortcut {
            UserDefaults.standard.set(["keyCode": shortcut.keyCode, "modifiers": shortcut.modifiers], forKey: Self.muteShortcutKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.muteShortcutKey)
        }
        return true
    }

    func pauseMuteShortcut(_ paused: Bool) {
        _ = muteHotkey.register(paused ? nil : muteShortcut)
    }

    func refresh() {
        opensAtLogin = LoginItem.isEnabled
    }

    private static var savedMuteShortcut: Shortcut? {
        guard let saved = UserDefaults.standard.dictionary(forKey: muteShortcutKey),
              let keyCode = saved["keyCode"] as? UInt32,
              let modifiers = saved["modifiers"] as? UInt32 else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: modifiers)
    }
}
