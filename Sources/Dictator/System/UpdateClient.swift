import AppUpdate
import Foundation

/// Talks to the embedded updater. Connection failures become a short message; a nil reply is success.
enum UpdateClient {
    static let replyTimeout = Duration.seconds(60)

    static func install(stagedApp: URL) async -> String? {
        await call { service, reply in
            service.install(stagedAppPath: stagedApp.path, reply: reply)
        }
    }

    static func removePreviousCopy() async -> String? {
        await call { service, reply in
            service.removePreviousCopy(reply: reply)
        }
    }

    private static func call(_ body: (DictatorUpdateInstalling, @escaping (String?) -> Void) -> Void) async -> String? {
        let exchange = Exchange()
        return await withCheckedContinuation { continuation in
            exchange.start(continuation: continuation, body: body)
        }
    }
}

private final class Exchange: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var connection: NSXPCConnection?
    private var timeout: Task<Void, Never>?
    private var finished = false

    func start(continuation: CheckedContinuation<String?, Never>, body: (DictatorUpdateInstalling, @escaping (String?) -> Void) -> Void) {
        self.continuation = continuation
        let connection = NSXPCConnection(serviceName: DictatorIdentity.updaterServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DictatorUpdateInstalling.self)
        // Hop off the XPC callback. Resuming the continuation synchronously from `resume()`
        // (the service is missing) traps.
        connection.invalidationHandler = { [weak self] in Task { self?.finish("Couldn't reach the updater.") } }
        connection.interruptionHandler = { [weak self] in Task { self?.finish("Couldn't reach the updater.") } }
        self.connection = connection
        connection.resume()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: UpdateClient.replyTimeout)
            self?.finish("The update took too long and was stopped.")
        }
        guard let service = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.finish("Couldn't reach the updater.")
        }) as? DictatorUpdateInstalling else {
            finish("Couldn't reach the updater.")
            return
        }
        body(service) { [weak self] message in self?.finish(message) }
    }

    private func finish(_ message: String?) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let connection = self.connection
        let timeout = self.timeout
        lock.unlock()
        timeout?.cancel()
        connection?.invalidate()
        continuation?.resume(returning: message)
    }
}
