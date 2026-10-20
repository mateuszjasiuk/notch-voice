import AppKit
import Combine

@main
@MainActor
enum NotchVoiceApp {
    private static let delegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--unregister-login-item") {
            LoginItem.setEnabled(false)
            return
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?
    private var settings: SettingsWindowController?
    private var permissions: PermissionCenter?
    private var speech: SpeechCenter?
    private var server: SocketServer?
    private var permissionSetting: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunning {
            NSApp.terminate(nil)
            return
        }
        let voice = VoiceController()
        let muteHotkey = Hotkey { [weak self] in
            voice.setEnabled(!voice.isEnabled)
            self?.notch?.flash()
        }
        let preferences = Preferences(muteHotkey: muteHotkey)
        let permissions = PermissionCenter()
        permissions.isEnabled = { preferences.asksForPermission }
        permissionSetting = preferences.$asksForPermission.dropFirst().filter { !$0 }.sink { _ in
            MainActor.assumeIsolated { permissions.handBackAll() }
        }
        self.permissions = permissions
        let speech = SpeechCenter(voice: voice)
        speech.mode = { preferences.readingMode }
        voice.speak = { speech.say($0) }
        self.speech = speech
        server = makeServer(permissions: permissions, speech: speech)
        let settings = SettingsWindowController(voice: voice, preferences: preferences)
        self.settings = settings
        notch = NotchController(voice: voice, speech: speech, preferences: preferences, permissions: permissions) { settings.show() }
        NSApp.mainMenu = makeMainMenu()
        LoginItem.enableOnFirstLaunch()
    }

    // Requests without a type come from permission hooks installed before types were added.
    private func makeServer(permissions: PermissionCenter, speech: SpeechCenter) -> SocketServer {
        let server = SocketServer(
            onRequest: { connection, line in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                        switch request["type"] as? String {
                        case nil, "permission": permissions.receive(request, from: connection)
                        default: connection.send(speech.handle(request))
                        }
                    }
                }
            },
            onClose: { connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { permissions.connectionClosed(connection.id) } }
            }
        )
        server.start()
        return server
    }

    @objc private func showSettings() {
        settings?.show()
    }

    private var isAlreadyRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0 != .current }
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit NotchVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
