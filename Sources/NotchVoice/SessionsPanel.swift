import SwiftUI

// The lower part of the open notch: what is being read, then each session with its unread count. A session opens
// to show its recent replies split into paragraphs, and anything in the list plays when clicked.
struct SessionsPanel: View {
    @ObservedObject var speech: SpeechCenter
    let accent: LinearGradient
    // Tells the notch how tall the list is, so it grows to fit it up to a limit and scrolls past that.
    let setListHeight: @MainActor (CGFloat) -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 8) {
            NowPlayingRow(speech: speech, accent: accent)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(speech.sessions.sessions) { session in
                        SessionRow(
                            session: session,
                            isExpanded: expanded.contains(session.id),
                            isSpeaking: speech.playback.current?.sessionID == session.id,
                            isMain: speech.mainSessionID == session.id,
                            accent: accent,
                            toggle: { toggle(session.id) },
                            setMain: { speech.setMain(sessionID: $0 ? session.id : nil) },
                            play: { if let latest = session.reply(back: 0) { speech.play(latest, in: session) } },
                            setMuted: { speech.setMuted(session, $0) }
                        )
                        if expanded.contains(session.id) {
                            ReplyList(session: session, speech: speech)
                                .transition(.opacity)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
                    setListHeight(height)
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func toggle(_ id: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}

private struct NowPlayingRow: View {
    @ObservedObject var speech: SpeechCenter
    let accent: LinearGradient

    var body: some View {
        HStack(spacing: 10) {
            if let current = speech.playback.current {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(status(reading: current.label, waiting: speech.playback.waiting.count))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 8)
                RoundIconButton(symbol: "forward.fill", label: "Skip") { speech.skip() }
                RoundIconButton(symbol: "stop.fill", label: "Stop") { speech.stop() }
            } else {
                let unread = speech.sessions.sessions.filter { !$0.isMuted }.reduce(0) { $0 + $1.unreadCount }
                Text(unread == 0 ? "All caught up" : "\(unread) unread repl\(unread == 1 ? "y" : "ies")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 8)
                if unread > 0 {
                    Button { speech.playNextUnread() } label: {
                        Label("Play next", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(accent))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 28)
    }

    private func status(reading label: String, waiting: Int) -> String {
        "Reading \(label)" + (waiting > 0 ? " · \(waiting) waiting" : "")
    }
}

private struct SessionRow: View {
    let session: Session
    let isExpanded: Bool
    let isSpeaking: Bool
    let isMain: Bool
    let accent: LinearGradient
    let toggle: () -> Void
    let setMain: (Bool) -> Void
    let play: () -> Void
    let setMuted: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide replies" : "Show replies")

            Button(action: play) {
                HStack(spacing: 8) {
                    Text(session.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(session.isMuted ? 0.4 : 0.95))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isSpeaking {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    Spacer(minLength: 6)
                    if session.unreadCount > 0 {
                        Text("\(session.unreadCount)")
                            .font(.system(size: 10.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 20, minHeight: 18)
                            .background(Capsule().fill(session.isMuted ? AnyShapeStyle(Color.white.opacity(0.2)) : AnyShapeStyle(accent)))
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play the latest reply")

            Button { setMain(!isMain) } label: {
                Image(systemName: isMain ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isMain ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.35)))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isMain ? "Stop treating this as the main session" : "Make this the main session: its replies are read, and the others are only announced")
            .accessibilityLabel(isMain ? "Unset main session" : "Make \(session.name) the main session")

            Button { setMuted(!session.isMuted) } label: {
                Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(session.isMuted ? 0.35 : 0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.isMuted ? "Read this session's replies again" : "Stop reading this session's replies")
            .accessibilityLabel(session.isMuted ? "Unmute \(session.name)" : "Mute \(session.name)")
        }
        .padding(.vertical, 2)
    }
}

private struct ReplyList: View {
    let session: Session
    @ObservedObject var speech: SpeechCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<session.replies.count, id: \.self) { back in
                if let reply = session.reply(back: back) {
                    VStack(alignment: .leading, spacing: 3) {
                        Button { speech.play(reply, in: session) } label: {
                            HStack(spacing: 6) {
                                Text(back == 0 ? "Latest" : "Earlier")
                                Text("·")
                                Text(reply.date.formatted(date: .omitted, time: .shortened))
                                if !reply.isRead {
                                    Circle().fill(Color.white.opacity(0.7)).frame(width: 5, height: 5)
                                }
                                Spacer()
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Play the whole reply")
                        ForEach(Array(reply.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            ParagraphRow(text: paragraph) { speech.playParagraph(paragraph, in: session) }
                        }
                    }
                }
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 4)
        .padding(.bottom, 8)
    }
}

private struct ParagraphRow: View {
    let text: String
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play this paragraph")
    }
}

private struct RoundIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
