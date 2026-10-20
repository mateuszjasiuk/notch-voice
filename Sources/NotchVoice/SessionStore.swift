import Foundation

struct Reply: Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    var isRead = false

    var paragraphs: [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct Session: Identifiable, Equatable {
    let id: String
    var name: String
    var requestedName: String
    var cwd: String?
    // The git worktree the session works in, or its folder when there is none.
    var root: String?
    var replies: [Reply] = []
    var isMuted = false
    var lastActivity: Date

    var unreadCount: Int { replies.filter { !$0.isRead }.count }

    // Long branch names are tiring to hear before every reply, so only their last part is read, without a ticket
    // number in front and at most three words: "feature/sch-605-horesta-spec-gaps" is read as "horesta spec gaps".
    var spokenName: String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        var words = last.split { "_-.".contains($0) || $0.isWhitespace }.map(String.init)
        if words.count > 2, words[0].allSatisfy(\.isLetter), words[1].allSatisfy(\.isNumber) {
            words.removeFirst(2)
        } else if words.count > 1, words[0].allSatisfy(\.isNumber) {
            words.removeFirst()
        }
        return words.isEmpty ? name : words.prefix(3).joined(separator: " ")
    }

    // 0 is the latest reply, 1 the one before it, and so on.
    func reply(back: Int) -> Reply? {
        back >= 0 && back < replies.count ? replies[replies.count - 1 - back] : nil
    }
}

enum SessionLookupError: Error, Equatable {
    case notFound(String)
    case ambiguous(String, [String])

    var message: String {
        switch self {
        case .notFound(let query): "No session matches \"\(query)\"."
        case .ambiguous(let query, let names): "\"\(query)\" matches \(names.joined(separator: ", ")). Type more of the name."
        }
    }
}

// Every Claude Code session that has replied, with its recent replies. Sessions are keyed by Claude's session id;
// two sessions that ask for the same name get "name-2", "name-3" and so on, so each name picks out one session.
struct SessionStore {
    static let historyLimit = 20
    static let sessionLimit = 30

    private(set) var sessions: [Session] = []

    @discardableResult
    mutating func add(sessionID: String, name: String, cwd: String?, root: String? = nil, text: String, date: Date = .now) -> Reply {
        let requested = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "session" : name
        let reply = Reply(id: UUID(), text: text, date: date)
        var session = sessions.first { $0.id == sessionID }
            ?? Session(id: sessionID, name: "", requestedName: "", cwd: cwd, lastActivity: date)
        sessions.removeAll { $0.id == sessionID }
        if session.requestedName != requested {
            session.requestedName = requested
            session.name = uniqueName(requested)
        }
        session.cwd = cwd ?? session.cwd
        session.root = root ?? session.root
        session.lastActivity = date
        session.replies.append(reply)
        session.replies.removeFirst(max(0, session.replies.count - Self.historyLimit))
        sessions.insert(session, at: 0)
        sessions.removeLast(max(0, sessions.count - Self.sessionLimit))
        return reply
    }

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    // An exact name or id wins. Then the start of a name or id, and then the start of any word in a name, so
    // "multi" finds "feature/multi-session-speech", whose name is spoken as "multi session speech".
    func session(matching query: String) -> Result<Session, SessionLookupError> {
        let query = query.lowercased()
        if let exact = sessions.first(where: { $0.name.lowercased() == query || $0.id.lowercased() == query }) {
            return .success(exact)
        }
        var matches = sessions.filter { $0.name.lowercased().hasPrefix(query) || $0.id.lowercased().hasPrefix(query) }
        if matches.isEmpty {
            matches = sessions.filter { session in
                session.name.lowercased().split { "/_-. ".contains($0) }.contains { $0.hasPrefix(query) }
            }
        }
        switch matches.count {
        case 0: return .failure(.notFound(query))
        case 1: return .success(matches[0])
        default: return .failure(.ambiguous(query, matches.map(\.name)))
        }
    }

    // A session that writes again after this starts over as a new one.
    mutating func remove(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
    }

    mutating func markRead(sessionID: String, replyID: UUID) {
        update(sessionID) { session in
            if let index = session.replies.firstIndex(where: { $0.id == replyID }) { session.replies[index].isRead = true }
        }
    }

    mutating func setMuted(sessionID: String, _ muted: Bool) {
        update(sessionID) { $0.isMuted = muted }
    }

    // The unread reply that has waited longest, leaving out muted sessions.
    func oldestUnread() -> (session: Session, reply: Reply)? {
        sessions.filter { !$0.isMuted }
            .flatMap { session in session.replies.filter { !$0.isRead }.map { (session: session, reply: $0) } }
            .min { $0.reply.date < $1.reply.date }
    }

    private mutating func update(_ sessionID: String, _ change: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        change(&sessions[index])
    }

    private func uniqueName(_ requested: String) -> String {
        let taken = Set(sessions.map { $0.name.lowercased() })
        guard taken.contains(requested.lowercased()) else { return requested }
        var number = 2
        while taken.contains("\(requested)-\(number)".lowercased()) { number += 1 }
        return "\(requested)-\(number)"
    }
}
