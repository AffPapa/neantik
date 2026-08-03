import Foundation
import Network

final class FingerprintAuditLoopbackSTUNServer: @unchecked Sendable {
    let port: NWEndpoint.Port

    private let listener: NWListener
    private let counter: RequestCounter

    private init(
        listener: NWListener,
        port: NWEndpoint.Port,
        counter: RequestCounter
    ) {
        self.listener = listener
        self.port = port
        self.counter = counter
    }

    static func start() async throws
        -> FingerprintAuditLoopbackSTUNServer
    {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let listener = try NWListener(using: parameters)
        let counter = RequestCounter()
        listener.newConnectionHandler = { connection in
            receiveMessages(on: connection, counter: counter)
        }

        let server = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<
                FingerprintAuditLoopbackSTUNServer,
                Error
            >) in
            let completionGate = CompletionGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port,
                          completionGate.claim()
                    else { return }
                    continuation.resume(
                        returning: FingerprintAuditLoopbackSTUNServer(
                            listener: listener,
                            port: port,
                            counter: counter
                        )
                    )
                case let .failed(error):
                    guard completionGate.claim() else { return }
                    continuation.resume(
                        throwing: NeAntikError.fingerprintAuditFailed(
                            "Не удалось запустить локальную STUN-проверку: " +
                                error.localizedDescription
                        )
                    )
                case .cancelled:
                    guard completionGate.claim() else { return }
                    continuation.resume(
                        throwing: NeAntikError.fingerprintAuditFailed(
                            "Локальная STUN-проверка была отменена."
                        )
                    )
                default:
                    break
                }
            }
            listener.start(
                queue: DispatchQueue(
                    label: "app.neantik.fingerprint-audit.stun"
                )
            )
        }

        do {
            try await server.verifyResponder()
            server.counter.reset()
            return server
        } catch {
            server.stop()
            throw error
        }
    }

    var acceptedRequestCount: Int {
        counter.snapshot()
    }

    func stop() {
        listener.cancel()
    }

    static func response(
        for datagram: Data,
        remoteEndpoint: NWEndpoint
    ) -> Data? {
        guard datagram.count >= 20,
              datagram.count <= 1_024,
              case let .hostPort(host, port) = remoteEndpoint,
              String(describing: host) == "127.0.0.1"
        else {
            return nil
        }
        let bytes = [UInt8](datagram)
        let messageType = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let declaredLength = Int(bytes[2]) << 8 | Int(bytes[3])
        guard messageType == 0x0001,
              declaredLength.isMultiple(of: 4),
              declaredLength + 20 == bytes.count,
              bytes[4...7].elementsEqual([0x21, 0x12, 0xA4, 0x42])
        else {
            return nil
        }

        let xorPort = port.rawValue ^ 0x2112
        let xorAddress: [UInt8] = [
            127 ^ 0x21,
            0 ^ 0x12,
            0 ^ 0xA4,
            1 ^ 0x42
        ]
        var response: [UInt8] = [
            0x01, 0x01,
            0x00, 0x0C,
            0x21, 0x12, 0xA4, 0x42
        ]
        response.append(contentsOf: bytes[8..<20])
        response.append(contentsOf: [
            0x00, 0x20,
            0x00, 0x08,
            0x00, 0x01,
            UInt8(xorPort >> 8),
            UInt8(xorPort & 0x00FF)
        ])
        response.append(contentsOf: xorAddress)
        return Data(response)
    }

    private static func receiveMessages(
        on connection: NWConnection,
        counter: RequestCounter
    ) {
        let queue = DispatchQueue(
            label: "app.neantik.fingerprint-audit.stun.connection"
        )
        connection.start(queue: queue)

        @Sendable func receiveNext() {
            connection.receiveMessage {
                content,
                _,
                _,
                error in
                guard error == nil else {
                    connection.cancel()
                    return
                }
                if let content,
                   let response = response(
                    for: content,
                    remoteEndpoint: connection.endpoint
                   )
                {
                    counter.increment()
                    connection.send(
                        content: response,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { sendError in
                            if sendError == nil {
                                receiveNext()
                            } else {
                                connection.cancel()
                            }
                        }
                    )
                } else {
                    receiveNext()
                }
            }
        }

        receiveNext()
    }

    private func verifyResponder() async throws {
        let transactionID = Array(UInt8(1)...UInt8(12))
        let request = Data(
            [
                0x00, 0x01,
                0x00, 0x00,
                0x21, 0x12, 0xA4, 0x42
            ] + transactionID
        )
        let connection = NWConnection(
            host: "127.0.0.1",
            port: port,
            using: .udp
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let completionGate = CompletionGate()
            let finish: @Sendable (Error?) -> Void = { error in
                guard completionGate.claim() else { return }
                connection.cancel()
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: request,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { sendError in
                            if let sendError {
                                finish(sendError)
                                return
                            }
                            connection.receiveMessage {
                                content,
                                _,
                                _,
                                receiveError in
                                guard receiveError == nil,
                                      let content,
                                      content.count == 32
                                else {
                                    finish(
                                        receiveError ??
                                            NeAntikError
                                            .fingerprintAuditFailed(
                                                "Локальная STUN-проверка не ответила."
                                            )
                                    )
                                    return
                                }
                                let bytes = [UInt8](content)
                                guard bytes[0] == 0x01,
                                      bytes[1] == 0x01,
                                      Array(bytes[8..<20]) == transactionID
                                else {
                                    finish(
                                        NeAntikError.fingerprintAuditFailed(
                                            "Локальная STUN-проверка вернула неверный ответ."
                                        )
                                    )
                                    return
                                }
                                finish(nil)
                            }
                        }
                    )
                case let .failed(error):
                    finish(error)
                case .cancelled:
                    finish(
                        NeAntikError.fingerprintAuditFailed(
                            "Локальная STUN self-test была отменена."
                        )
                    )
                default:
                    break
                }
            }
            connection.start(
                queue: DispatchQueue(
                    label: "app.neantik.fingerprint-audit.stun.self-test"
                )
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                finish(
                    NeAntikError.fingerprintAuditFailed(
                        "Локальная STUN self-test превысила время ожидания."
                    )
                )
            }
        }
    }

    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count = min(count + 1, 256)
            lock.unlock()
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }

        func snapshot() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}
