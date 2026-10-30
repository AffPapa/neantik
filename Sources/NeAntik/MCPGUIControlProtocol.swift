import Foundation

/// Closed local GUI lifecycle protocol. Metadata, launch flags, URLs, scripts,
/// page contents and credentials cannot be expressed by these messages.
enum MCPGUIControlProtocol {
    static let maximumMessageBytes = 4096
    enum Command: String, Codable, Sendable { case connect, start, status, stop }
    enum Failure: String, Error, Codable, Sendable {
        case malformed, unavailable, consentRequired, denied, revisionConflict
        case staleSession, busy, saveFailed, ownershipLost
    }
    enum State: String, Codable, Sendable { case pendingConsent, connected, managed, stopPending, stopped, saveFailed, notOwned, ownershipLost }

    struct Request: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let endpointGeneration: UUID
        let libraryIdentitySHA256: String
        let connectionGeneration: UUID?
        let sequence: String
        let operation: Command
        let profileID: UUID?
        let expectedRevision: String?

        init(endpointGeneration: UUID, libraryIdentitySHA256: String, connectionGeneration: UUID? = nil,
             sequence: UInt64, operation: Command, profileID: UUID? = nil, expectedRevision: UInt64? = nil) {
            schemaVersion = 1; self.endpointGeneration = endpointGeneration; self.libraryIdentitySHA256 = libraryIdentitySHA256
            self.connectionGeneration = connectionGeneration; self.sequence = String(sequence); self.operation = operation
            self.profileID = profileID; self.expectedRevision = expectedRevision.map(String.init)
        }

        func validate() throws {
            guard schemaVersion == 1, Self.hash(libraryIdentitySHA256), let number = Self.decimal(sequence), number > 0,
                  endpointGeneration != Self.zero else { throw Failure.malformed }
            switch operation {
            case .connect:
                guard connectionGeneration == nil, profileID == nil, expectedRevision == nil, number == 1 else { throw Failure.malformed }
            case .start:
                guard let connectionGeneration, connectionGeneration != Self.zero, let profileID, profileID != Self.zero,
                      let expectedRevision, Self.decimal(expectedRevision) != nil else { throw Failure.malformed }
            case .status, .stop:
                guard let connectionGeneration, connectionGeneration != Self.zero, let profileID, profileID != Self.zero,
                      expectedRevision == nil else { throw Failure.malformed }
            }
        }
        static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        static func decimal(_ value: String) -> UInt64? {
            guard !value.isEmpty, value.utf8.count <= 20, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt64(value), String(number) == value else { return nil }
            return number
        }
        static func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    }

    struct Reply: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let endpointGeneration: UUID
        let connectionGeneration: UUID?
        let sequence: String
        let operation: Command
        let state: State?
        let profileID: UUID?
        let revision: String?
        let failure: Failure?
        let stopRequested: Bool?

        init(request: Request, connectionGeneration: UUID?, state: State? = nil, revision: UInt64? = nil, failure: Failure? = nil, stopRequested: Bool? = nil) {
            schemaVersion = 1; endpointGeneration = request.endpointGeneration
            self.connectionGeneration = connectionGeneration; sequence = request.sequence; operation = request.operation
            self.state = state; profileID = request.profileID; self.revision = revision.map(String.init); self.failure = failure
            self.stopRequested = stopRequested
        }
    }

    static func decodeRequest(_ data: Data) throws -> Request {
        try shape(data, keys: ["schemaVersion", "endpointGeneration", "libraryIdentitySHA256", "connectionGeneration", "sequence", "operation", "profileID", "expectedRevision"])
        let value = try JSONDecoder().decode(Request.self, from: data)
        try value.validate(); return value
    }

    static func decodeReply(_ data: Data, request: Request, expectedConnection: UUID?) throws -> Reply {
        try shape(data, keys: ["schemaVersion", "endpointGeneration", "connectionGeneration", "sequence", "operation", "state", "profileID", "revision", "failure", "stopRequested"])
        let value = try JSONDecoder().decode(Reply.self, from: data)
        guard value.schemaVersion == 1, value.endpointGeneration == request.endpointGeneration,
              value.sequence == request.sequence, value.operation == request.operation, value.profileID == request.profileID,
              let connection = value.connectionGeneration, connection != Request.zero,
              expectedConnection == nil || value.connectionGeneration == expectedConnection,
              value.revision == nil || Request.decimal(value.revision!) != nil,
              (value.state != nil) != (value.failure != nil) else { throw Failure.malformed }
        if value.failure != nil {
            guard value.revision == nil, value.stopRequested == nil else { throw Failure.malformed }
        } else {
            guard let state = value.state else { throw Failure.malformed }
            guard (request.operation == .stop) == (value.stopRequested != nil) else { throw Failure.malformed }
            switch request.operation {
            case .connect:
                guard [.pendingConsent, .connected].contains(state), value.revision == nil else { throw Failure.malformed }
            case .start:
                guard value.state == .managed, value.revision != nil else { throw Failure.malformed }
            case .status:
                guard [.managed, .stopPending, .stopped, .saveFailed, .notOwned, .ownershipLost].contains(state) else { throw Failure.malformed }
            case .stop:
                guard [.stopPending, .stopped, .saveFailed, .ownershipLost].contains(state) else { throw Failure.malformed }
            }
        }
        return value
    }

    private static func shape(_ data: Data, keys: Set<String>) throws {
        guard !data.isEmpty, data.count <= maximumMessageBytes else { throw Failure.malformed }
        try ImportJSONShape.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: keys) else { throw Failure.malformed }
    }
}
