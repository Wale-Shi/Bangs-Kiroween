import Darwin
import Foundation
import BangsCore

/// A connection that is waiting for the user's answer to a permission request.
final class PendingReply: @unchecked Sendable {
    private let fd: Int32
    private var source: DispatchSourceRead?
    private let lock = NSLock()

    init(fd: Int32, onHangUp: @escaping @Sendable () -> Void) {
        self.fd = fd
        // The hook never writes again, so readable means EOF: the CLI timed out or the session went away.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self, let source = self.finish() else { return }
            source.cancel()
            onHangUp()
        }
        // Cancelling is asynchronous: closed any sooner, the number could be reused by the next accept while the source
        // still watches it. This is the one place the descriptor is closed.
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// Never answered (dropped unanswered): the connection still has to be let go.
    deinit { source?.cancel() }

    func answer(_ reply: PermissionReply) {
        guard let source = finish() else { return }
        // Written before the cancel, so the descriptor is still open.
        _ = UnixSocket.write(fd, reply.line)
        source.cancel()
    }

    /// Takes the connection over once: the source to cancel, or nil if it was already finished. A hang-up cancels at
    /// once; an answer cancels after writing.
    private func finish() -> DispatchSourceRead? {
        lock.lock(); defer { lock.unlock() }
        guard let source else { return nil }
        self.source = nil
        return source
    }
}

/// Listens on the notch socket and hands each hook event to the main actor.
final class HookServer: @unchecked Sendable {
    private let listener: Int32
    private let onEvent: @MainActor (HookEnvelope, PendingReply?) -> Void
    private let onHangUp: @MainActor (ObjectIdentifier) -> Void
    /// Events are read one at a time, in the order the hooks connected, which is the order they fired: read in
    /// parallel, a turn's last PostToolUse could overtake its Stop and leave the session looking busy.
    private let queue = DispatchQueue(label: "bangs.hooks")

    /// Nil when another Bangs is already listening.
    init?(onEvent: @escaping @MainActor (HookEnvelope, PendingReply?) -> Void, onHangUp: @escaping @MainActor (ObjectIdentifier) -> Void) {
        try? FileManager.default.createDirectory(at: Wire.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let listener = UnixSocket.listen(at: Wire.socketPath) else { return nil }
        self.listener = listener
        self.onEvent = onEvent
        self.onHangUp = onHangUp
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; return }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // A hook writes its event as soon as it connects; one that does not must not hold up the others.
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            queue.async { [self] in handle(fd) }
        }
    }

    private func handle(_ fd: Int32) {
        guard let line = UnixSocket.readLine(fd), let envelope = HookEnvelope(line: line) else { close(fd); return }
        guard envelope.event == .permissionRequest else {
            close(fd)
            DispatchQueue.main.async { [onEvent] in MainActor.assumeIsolated { onEvent(envelope, nil) } }
            return
        }
        let box = PendingBox()
        let pending = PendingReply(fd: fd) { [onHangUp] in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let id = box.id { onHangUp(id) } } }
        }
        box.id = ObjectIdentifier(pending)
        DispatchQueue.main.async { [onEvent] in MainActor.assumeIsolated { onEvent(envelope, pending) } }
    }
}

private final class PendingBox: @unchecked Sendable { var id: ObjectIdentifier? }
