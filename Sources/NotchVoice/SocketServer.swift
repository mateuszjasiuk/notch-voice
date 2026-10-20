import Foundation
import os

private let log = Logger(subsystem: "local.notchvoice", category: "socket")

// Listens on a Unix socket for the hooks and the nv command. Each connection carries one JSON request line and gets
// one JSON reply line; if the client goes away first (Claude answered elsewhere or gave up), the connection reports
// it closed. CONTRIBUTING.md describes the messages.
final class SocketServer: @unchecked Sendable {
    static let socketPath = URL(filePath: NSTemporaryDirectory()).appending(path: "notchvoice.sock").path

    private let queue = DispatchQueue(label: "local.notchvoice.socket")
    private let onRequest: @Sendable (SocketConnection, Data) -> Void
    private let onClose: @Sendable (SocketConnection) -> Void
    private var listener: DispatchSourceRead?

    init(onRequest: @escaping @Sendable (SocketConnection, Data) -> Void, onClose: @escaping @Sendable (SocketConnection) -> Void) {
        self.onRequest = onRequest
        self.onClose = onClose
    }

    func start() {
        queue.async { self.listen() }
    }

    private func listen() {
        let path = Self.socketPath
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return log.error("socket() failed: \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return log.error("socket path is too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(descriptor, 16) == 0 else {
            close(descriptor)
            return log.error("could not listen on \(path): \(errno)")
        }
        chmod(path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(from: descriptor) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        listener = source
    }

    private func accept(from descriptor: Int32) {
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        // A client that hangs up before its reply is written must not take the app down with SIGPIPE.
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connection = SocketConnection(descriptor: client, queue: queue)
        connection.start(
            onLine: { [onRequest] line in onRequest(connection, line) },
            onClose: { [onClose] in onClose(connection) }
        )
    }
}

final class SocketConnection: @unchecked Sendable, Identifiable {
    let id = UUID()
    private let descriptor: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var hasRequest = false
    private var isFinished = false

    init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        self.queue = queue
    }

    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else {
                if !isFinished {
                    isFinished = true
                    onClose()
                }
                self.source?.cancel()
                return
            }
            guard !hasRequest else { return }
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                hasRequest = true
                onLine(buffer[buffer.startIndex..<newline])
            }
        }
        source.setCancelHandler { [self] in
            close(descriptor)
            self.source = nil
        }
        self.source = source
        source.resume()
    }

    func reply(_ decision: String) {
        send(["decision": decision])
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(UInt8(ascii: "\n"))
        let line = data
        queue.async { [self] in
            guard !isFinished else { return }
            isFinished = true
            line.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            source?.cancel()
        }
    }
}
