import Foundation
import Testing
@testable import NotchVoice

struct SessionStoreTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func repliesAreKeptPerSessionWithTheMostRecentSessionFirst() {
        var store = SessionStore()
        store.add(sessionID: "a", name: "api", cwd: "/w/api", text: "one", date: start)
        store.add(sessionID: "b", name: "web", cwd: "/w/web", text: "two", date: start + 1)
        store.add(sessionID: "a", name: "api", cwd: "/w/api", text: "three", date: start + 2)
        #expect(store.sessions.map(\.name) == ["api", "web"])
        #expect(store.session(id: "a")?.replies.map(\.text) == ["one", "three"])
        #expect(store.session(id: "a")?.unreadCount == 2)
    }

    @Test func historyKeepsTheLatestTwentyReplies() {
        var store = SessionStore()
        for number in 1...25 { store.add(sessionID: "a", name: "api", cwd: nil, text: "\(number)") }
        let session = store.session(id: "a")!
        #expect(session.replies.count == SessionStore.historyLimit)
        #expect(session.reply(back: 0)?.text == "25")
        #expect(session.reply(back: 19)?.text == "6")
        #expect(session.reply(back: 20) == nil)
    }

    @Test func sessionsWithTheSameNameGetANumber() {
        var store = SessionStore()
        store.add(sessionID: "a", name: "main", cwd: nil, text: "x")
        store.add(sessionID: "b", name: "main", cwd: nil, text: "x")
        store.add(sessionID: "c", name: "main", cwd: nil, text: "x")
        store.add(sessionID: "a", name: "main", cwd: nil, text: "again")
        #expect(store.session(id: "a")?.name == "main")
        #expect(store.session(id: "b")?.name == "main-2")
        #expect(store.session(id: "c")?.name == "main-3")
    }

    @Test func aSessionThatSwitchesBranchTakesTheNewName() {
        var store = SessionStore()
        store.add(sessionID: "a", name: "main", cwd: nil, text: "x")
        store.add(sessionID: "a", name: "feat/api", cwd: nil, text: "y")
        #expect(store.session(id: "a")?.name == "feat/api")
    }

    @Test func sessionsAreFoundByAUniquePrefix() throws {
        var store = SessionStore()
        store.add(sessionID: "id-1", name: "api", cwd: nil, text: "x")
        store.add(sessionID: "id-2", name: "api-docs", cwd: nil, text: "x")
        store.add(sessionID: "id-3", name: "web", cwd: nil, text: "x")
        #expect(try store.session(matching: "api").get().id == "id-1")
        #expect(try store.session(matching: "API-D").get().id == "id-2")
        #expect(try store.session(matching: "w").get().id == "id-3")
        #expect(try store.session(matching: "id-3").get().name == "web")
        #expect(throws: SessionLookupError.ambiguous("ap", ["api-docs", "api"])) { try store.session(matching: "ap").get() }
        #expect(throws: SessionLookupError.notFound("x")) { try store.session(matching: "x").get() }
    }

    @Test func sessionsAreFoundByTheStartOfAnyWordInTheirName() throws {
        var store = SessionStore()
        store.add(sessionID: "id-1", name: "feature/multi-session-speech", cwd: nil, text: "x")
        store.add(sessionID: "id-2", name: "sch-599-supplement-percentage", cwd: nil, text: "x")
        store.add(sessionID: "id-3", name: "fix/session-names", cwd: nil, text: "x")
        #expect(try store.session(matching: "multi").get().id == "id-1")
        #expect(try store.session(matching: "suppl").get().id == "id-2")
        #expect(try store.session(matching: "fix").get().id == "id-3")
        #expect(throws: SessionLookupError.ambiguous("session", ["fix/session-names", "feature/multi-session-speech"])) {
            try store.session(matching: "session").get()
        }
    }

    @Test func aRemovedSessionStartsOverWhenItWritesAgain() {
        var store = SessionStore()
        store.add(sessionID: "a", name: "api", cwd: nil, text: "one")
        store.add(sessionID: "a", name: "api", cwd: nil, text: "two")
        store.setMuted(sessionID: "a", true)
        store.remove(sessionID: "a")
        #expect(store.session(id: "a") == nil)
        #expect(store.oldestUnread() == nil)
        store.add(sessionID: "a", name: "api", cwd: nil, text: "three")
        #expect(store.session(id: "a")?.replies.map(\.text) == ["three"])
        #expect(store.session(id: "a")?.isMuted == false)
    }

    @Test func theOldestUnreadReplySkipsMutedSessions() {
        var store = SessionStore()
        let first = store.add(sessionID: "a", name: "api", cwd: nil, text: "first", date: start)
        store.add(sessionID: "b", name: "web", cwd: nil, text: "second", date: start + 1)
        #expect(store.oldestUnread()?.reply.text == "first")
        store.markRead(sessionID: "a", through: first.id)
        #expect(store.oldestUnread()?.reply.text == "second")
        store.setMuted(sessionID: "b", true)
        #expect(store.oldestUnread() == nil)
    }

    @Test func readingAReplyAlsoReadsTheOnesBeforeIt() {
        var store = SessionStore()
        store.add(sessionID: "a", name: "api", cwd: nil, text: "one")
        let two = store.add(sessionID: "a", name: "api", cwd: nil, text: "two")
        store.add(sessionID: "a", name: "api", cwd: nil, text: "three")
        store.add(sessionID: "b", name: "web", cwd: nil, text: "other")
        store.markRead(sessionID: "a", through: two.id)
        #expect(store.session(id: "a")?.replies.map(\.isRead) == [true, true, false])
        #expect(store.session(id: "b")?.unreadCount == 1)
    }

    @Test func markAllReadCoversOneSessionOrAll() {
        var store = SessionStore()
        store.add(sessionID: "a", name: "api", cwd: nil, text: "one")
        store.add(sessionID: "a", name: "api", cwd: nil, text: "two")
        store.add(sessionID: "b", name: "web", cwd: nil, text: "other")
        store.markAllRead(sessionID: "a")
        #expect(store.session(id: "a")?.unreadCount == 0)
        #expect(store.session(id: "b")?.unreadCount == 1)
        store.markAllRead()
        #expect(store.oldestUnread() == nil)
    }

    @Test(arguments: [
        ("feat/api-fix_2", "api fix 2"),
        ("sch-605-horesta-spec-gaps", "horesta spec gaps"),
        ("feature/multi-session-speech-and-more", "multi session speech"),
        ("1234-fix-login", "fix login"),
        ("main-2", "main 2"),
        ("Claude chat", "Claude chat"),
    ])
    func branchNamesAreShortenedForSpeech(name: String, spoken: String) {
        var store = SessionStore()
        store.add(sessionID: "a", name: name, cwd: nil, text: "x")
        #expect(store.session(id: "a")?.spokenName == spoken)
    }

    @Test func repliesSplitIntoParagraphs() {
        let reply = Reply(id: UUID(), text: "First part.\n\n  Second part.\n\n\n\nThird.", date: start)
        #expect(reply.paragraphs == ["First part.", "Second part.", "Third."])
    }
}

struct PlaybackQueueTests {
    private func reply(_ label: String) -> Utterance {
        Utterance(text: label, label: label, sessionID: label, replyID: UUID())
    }

    @Test func repliesWaitTheirTurn() {
        var queue = PlaybackQueue()
        let first = queue.enqueue(reply("a"))
        let second = queue.enqueue(reply("b"))
        #expect(first)
        #expect(!second)
        #expect(queue.current?.label == "a")
        let next = queue.advance()
        let last = queue.advance()
        #expect(next?.label == "b")
        #expect(last == nil)
    }

    @Test func aRequestCutsInAndTheCutOffReplyIsReadAgainAfterIt() {
        var queue = PlaybackQueue()
        _ = queue.enqueue(reply("a"))
        _ = queue.enqueue(reply("b"))
        queue.interrupt(with: Utterance(text: "hi", label: "Text", isRequested: true))
        #expect(queue.current?.label == "Text")
        #expect(queue.waiting.map(\.label) == ["a", "b"])
    }

    @Test func aRequestThatIsCutOffIsNotRepeated() {
        var queue = PlaybackQueue()
        queue.interrupt(with: Utterance(text: "one", label: "one", isRequested: true))
        queue.interrupt(with: Utterance(text: "two", label: "two", isRequested: true))
        #expect(queue.waiting.isEmpty)
    }

    @Test func stoppingClearsEverything() {
        var queue = PlaybackQueue()
        _ = queue.enqueue(reply("a"))
        _ = queue.enqueue(reply("b"))
        queue.clear()
        #expect(queue.current == nil)
        #expect(queue.waiting.isEmpty)
    }
}
