import Foundation
import Network

/// Errors thrown by `RawSocketTransport` during TCP connection or transmission.
enum RawSocketError: Error, LocalizedError, Sendable, Equatable {
    case invalidPort(Int)
    case notConnected
    case connectionFailed(String)
    case connectionCancelled
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid TCP port \(port)."
        case .notConnected:
            "Raw socket transport is not connected."
        case .connectionFailed(let reason):
            "Raw socket connection failed: \(reason)"
        case .connectionCancelled:
            "Raw socket connection was cancelled."
        case .sendFailed(let reason):
            "Raw socket send failed: \(reason)"
        }
    }
}

/// Raw TCP port 9100 (AppSocket / JetDirect) transport using `Network.framework`.
///
/// Used as a direct byte-stream fallback for printer command languages
/// (such as HP-RTL or ESC/P-R) that cannot be carried over IPP.
actor RawSocketTransport {
    let host: String
    let port: Int

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "T2170Print.RawSocketTransport")

    init(host: String, port: Int = 9100) {
        self.host = host
        self.port = port
    }

    /// Opens the TCP connection to `host:port` and waits until the socket is ready.
    func connect() async throws {
        if let existing = connection, case .ready = existing.state {
            return
        }
        close()

        guard let rawPort = UInt16(exactly: port),
              let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw RawSocketError.invalidPort(port)
        }

        let nwConnection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        self.connection = nwConnection

        let gate = ContinuationGate<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.set(continuation)
            nwConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    nwConnection.stateUpdateHandler = nil
                    gate.resume(with: .success(()))
                case .failed(let error):
                    nwConnection.stateUpdateHandler = nil
                    gate.resume(with: .failure(RawSocketError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    nwConnection.stateUpdateHandler = nil
                    gate.resume(with: .failure(RawSocketError.connectionCancelled))
                default:
                    break
                }
            }
            nwConnection.start(queue: queue)
        }
    }

    /// Sends raw bytes over the connected TCP socket.
    func send(_ data: Data) async throws {
        if connection == nil {
            try await connect()
        }
        guard let activeConnection = connection else {
            throw RawSocketError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activeConnection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: RawSocketError.sendFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    /// Closes the active TCP connection, if any.
    func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }
}

/// Lock-guarded continuation wrapper ensuring a state handler resumes at most once.
private final class ContinuationGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(with: result)
        } else if pendingResult == nil {
            pendingResult = result
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}
