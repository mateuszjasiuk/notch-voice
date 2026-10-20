import Combine
import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "speech")

struct Utterance: Identifiable, Equatable {
    let id = UUID()
    let text: String
    // What the notch shows for it: the session's name, or "Text" for nv say.
    let label: String
    var sessionID: String?
    var replyID: UUID?
    // Asked for by the user (nv, /read, a click), rather than queued because a reply arrived.
    var isRequested = false
}

// One thing speaks at a time. Replies that arrive wait their turn; something the user asks for plays straight away,
// and a reply it cuts off goes back to the front of the queue to be read again from the start.
struct PlaybackQueue: Equatable {
    private(set) var current: Utterance?
    private(set) var waiting: [Utterance] = []

    // Returns true when the speaker was free, so the utterance should start now.
    mutating func enqueue(_ utterance: Utterance) -> Bool {
        guard current != nil else {
            current = utterance
            return true
        }
        waiting.append(utterance)
        return false
    }

    mutating func interrupt(with utterance: Utterance) {
        if let stopped = current, !stopped.isRequested, stopped.replyID != nil {
            waiting.insert(stopped, at: 0)
        }
        current = utterance
    }

    mutating func advance() -> Utterance? {
        current = waiting.isEmpty ? nil : waiting.removeFirst()
        return current
    }

    mutating func clear() {
        current = nil
        waiting.removeAll()
    }

    mutating func removeWaiting(where shouldRemove: (Utterance) -> Bool) {
        waiting.removeAll(where: shouldRemove)
    }
}

@MainActor
final class SpeechCenter: ObservableObject {
    @Published private(set) var sessions = SessionStore()
    @Published private(set) var playback = PlaybackQueue()
    var mode: () -> ReadingMode = { .focusedSession }
    enum Focus: Equatable {
        // The session the user last wrote a prompt to, from notchvoice_brief.py.
        case session(String)
        // A worktree the user switched to in their editor, from nv focus.
        case folder(String)
    }

    // Whichever came last: a prompt, or the editor.
    private(set) var focus: Focus?
    // The session the user chose as main, with /main, nv main or the star in the notch. It wins over the last prompt.
    @Published private(set) var mainSessionID: String?

    private let voice: VoiceController
    private let ducker = MusicDucker()
    private var process: Process?
    private var textFile: URL?
    private var voiceSwitch: AnyCancellable?

    var isSpeaking: Bool { playback.current != nil }

    init(voice: VoiceController) {
        self.voice = voice
        // Turning voice replies off stops the speech straight away, as it always has.
        voiceSwitch = voice.$isEnabled.dropFirst().removeDuplicates().filter { !$0 }.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func receive(sessionID: String, name: String, cwd: String?, root: String?, text: String, date: Date) {
        let reply = sessions.add(sessionID: sessionID, name: name, cwd: cwd, root: root, text: text, date: date)
        guard let session = sessions.session(id: sessionID) else { return }
        voice.refresh()
        guard voice.isEnabled, !session.isMuted else { return }
        switch mode() {
        case .focusedSession where isFocused(session):
            // You know which session you're working in, so its replies skip the name.
            enqueue(utterance(for: reply, in: session, requested: false, announced: false))
        case .autoRead:
            enqueue(utterance(for: reply, in: session, requested: false))
        case .focusedSession, .announceOnly:
            enqueue(Utterance(text: "New response from \(session.spokenName).", label: session.name, sessionID: sessionID))
        }
    }

    func setFocus(_ focus: Focus) {
        self.focus = focus
    }

    func setMain(sessionID: String?) {
        mainSessionID = sessionID
    }

    // Takes the session's replies out of the queue. A reply already being read finishes, because a session usually
    // ends right after its last reply and cutting that off would be abrupt.
    func remove(sessionID: String) {
        sessions.remove(sessionID: sessionID)
        playback.removeWaiting { $0.sessionID == sessionID }
        if mainSessionID == sessionID { mainSessionID = nil }
        if focus == .session(sessionID) { focus = nil }
    }

    // Before the first prompt there is nothing to go on, so every session counts. Desktop chats have no prompt hook,
    // and their speak tool is only called in the chat the user is looking at.
    private func isFocused(_ session: Session) -> Bool {
        if session.id == "claude-desktop" { return true }
        if let mainSessionID { return session.id == mainSessionID }
        switch focus {
        case nil: return true
        case .session(let id): return session.id == id
        case .folder(let folder): return session.root == folder || session.cwd == folder
        }
    }

    func say(_ text: String) {
        interrupt(with: Utterance(text: text, label: "Text", isRequested: true))
    }

    func play(_ reply: Reply, in session: Session) {
        interrupt(with: utterance(for: reply, in: session, requested: true))
    }

    func playParagraph(_ text: String, in session: Session) {
        interrupt(with: Utterance(text: text, label: session.name, sessionID: session.id, isRequested: true))
    }

    @discardableResult
    func playNextUnread() -> Bool {
        guard let (session, reply) = sessions.oldestUnread() else { return false }
        play(reply, in: session)
        return true
    }

    func skip() {
        stopProcess()
        advance()
    }

    func stop() {
        playback.clear()
        stopProcess()
        ducker.restore()
    }

    // `say` runs on after the app quits unless it is stopped, so it would talk over the next copy of the app.
    func shutDown() {
        playback.clear()
        stopProcess()
        ducker.restoreNow()
    }

    func setMuted(_ session: Session, _ muted: Bool) {
        sessions.setMuted(sessionID: session.id, muted)
        guard muted else { return }
        playback.removeWaiting { $0.sessionID == session.id && !$0.isRequested }
        if let current = playback.current, current.sessionID == session.id, !current.isRequested { skip() }
    }

    private func utterance(for reply: Reply, in session: Session, requested: Bool, announced: Bool = true) -> Utterance {
        Utterance(
            text: announced ? "Response from \(session.spokenName). [[slnc 300]] \(reply.text)" : reply.text,
            label: session.name, sessionID: session.id, replyID: reply.id, isRequested: requested
        )
    }

    private func enqueue(_ utterance: Utterance) {
        if playback.enqueue(utterance) { start(utterance) }
    }

    private func interrupt(with utterance: Utterance) {
        playback.interrupt(with: utterance)
        start(utterance)
    }

    private func advance() {
        if let next = playback.advance() {
            start(next)
        } else {
            ducker.restore()
        }
    }

    private func start(_ utterance: Utterance) {
        stopProcess()
        if let sessionID = utterance.sessionID, let replyID = utterance.replyID {
            sessions.markRead(sessionID: sessionID, replyID: replyID)
        }
        ducker.duck(to: voice.musicVolume)
        // A file rather than a pipe, so a long reply never blocks on a full pipe and a stopped say can't SIGPIPE us.
        let file = FileManager.default.temporaryDirectory.appending(path: "notchvoice-\(utterance.id).txt")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/say")
        process.arguments = voice.sayArguments + ["-f", file.path]
        process.terminationHandler = { [weak self] finished in
            let pid = finished.processIdentifier
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(pid) } }
        }
        do {
            try utterance.text.write(to: file, atomically: true, encoding: .utf8)
            try process.run()
            self.process = process
            textFile = file
            log.info("speaking \(utterance.label, privacy: .public), \(self.playback.waiting.count) waiting")
        } catch {
            log.error("could not run say: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: file)
            advance()
        }
    }

    private func finished(_ pid: pid_t) {
        guard let process, process.processIdentifier == pid else { return }
        removeTextFile()
        self.process = nil
        advance()
    }

    private func stopProcess() {
        guard let process else { return }
        // Cleared first, so its termination handler finds nothing to advance.
        self.process = nil
        process.terminate()
        removeTextFile()
    }

    private func removeTextFile() {
        if let textFile { try? FileManager.default.removeItem(at: textFile) }
        textFile = nil
    }
}

// The requests that come in over the socket, apart from permission requests. CONTRIBUTING.md lists them.
extension SpeechCenter {
    func handle(_ request: [String: Any]) -> [String: Any] {
        switch request["type"] as? String {
        case "reply":
            guard let text = request["text"] as? String, !text.isEmpty else { return failure("A reply needs text.") }
            let sessionID = request["session_id"] as? String ?? "unknown"
            let timestamp = request["timestamp"] as? Double
            receive(
                sessionID: sessionID,
                name: request["session_name"] as? String ?? "",
                cwd: request["cwd"] as? String,
                root: request["root"] as? String,
                text: text,
                date: timestamp.map(Date.init(timeIntervalSince1970:)) ?? .now
            )
            return ["ok": true]
        case "focus":
            if let sessionID = request["session_id"] as? String, !sessionID.isEmpty {
                setFocus(.session(sessionID))
            } else if let folder = request["root"] as? String, !folder.isEmpty {
                setFocus(.folder(folder))
            } else {
                return failure("Focus needs a session_id or a root.")
            }
            return ["ok": true]
        case "main":
            if request["off"] as? Bool == true {
                setMain(sessionID: nil)
                return ["ok": true]
            }
            // A session that hasn't replied yet can still be made main, by its id.
            if let sessionID = request["session_id"] as? String, !sessionID.isEmpty {
                setMain(sessionID: sessionID)
                return ["ok": true, "session": sessions.session(id: sessionID)?.name ?? "this session"]
            }
            guard let query = request["session"] as? String, !query.isEmpty else { return failure("Say which session to make main.") }
            return withSession(request) { session in
                setMain(sessionID: session.id)
                return ["ok": true, "session": session.name]
            }
        case "remove":
            // The SessionEnd hook sends the id; it is fine if that session never replied.
            if let sessionID = request["session_id"] as? String, !sessionID.isEmpty {
                remove(sessionID: sessionID)
                return ["ok": true]
            }
            guard let query = request["session"] as? String, !query.isEmpty else { return failure("Say which session to remove.") }
            return withSession(request) { session in
                remove(sessionID: session.id)
                return ["ok": true, "session": session.name]
            }
        case "say":
            guard let text = request["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failure("There was nothing to say.")
            }
            say(text)
            return ["ok": true]
        case "list":
            return [
                "ok": true,
                "mode": mode().rawValue,
                "speaking": playback.current?.label ?? NSNull(),
                "waiting": playback.waiting.count,
                "sessions": sessions.sessions.map(describe),
            ]
        case "history":
            return withSession(request) { session in
                let count = request["count"] as? Int ?? SessionStore.historyLimit
                let replies = (0..<min(count, session.replies.count)).compactMap { back in
                    session.reply(back: back).map { ["index": back, "text": $0.text, "date": $0.date.ISO8601Format(), "read": $0.isRead] as [String: Any] }
                }
                return ["ok": true, "session": describe(session), "replies": replies]
            }
        case "read":
            return withSession(request) { session in
                let back = request["back"] as? Int ?? 0
                guard let reply = session.reply(back: back) else {
                    return failure("\(session.name) has \(session.replies.count) repl\(session.replies.count == 1 ? "y" : "ies").")
                }
                play(reply, in: session)
                return ["ok": true, "session": session.name]
            }
        case "next":
            return playNextUnread() ? ["ok": true] : failure("There are no unread replies.")
        case "skip":
            skip()
            return ["ok": true]
        case "stop":
            stop()
            return ["ok": true]
        case "mute", "unmute":
            let muted = request["type"] as? String == "mute"
            return withSession(request) { session in
                setMuted(session, muted)
                return ["ok": true, "session": session.name]
            }
        case let type:
            return failure("Unknown request type: \(type ?? "none").")
        }
    }

    // Without a session name, the session that replied most recently.
    private func withSession(_ request: [String: Any], _ body: (Session) -> [String: Any]) -> [String: Any] {
        let query = (request["session"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if query.isEmpty {
            guard let latest = sessions.sessions.first else { return failure("No session has replied yet.") }
            return body(latest)
        }
        switch sessions.session(matching: query) {
        case .success(let session): return body(session)
        case .failure(let error): return failure(error.message)
        }
    }

    private func describe(_ session: Session) -> [String: Any] {
        [
            "id": session.id,
            "name": session.name,
            "cwd": session.cwd ?? NSNull(),
            "unread": session.unreadCount,
            "replies": session.replies.count,
            "muted": session.isMuted,
            "main": session.id == mainSessionID,
            "last_activity": session.lastActivity.ISO8601Format(),
        ]
    }

    private func failure(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }
}
