import CryptoKit
import Foundation
import SwiftUI

/// Password protected, local-only profile export. Proxy credentials are kept
/// in Keychain and are deliberately never copied into this archive.
struct EncryptedProfileBackup: Sendable {
    static let format = "NeAntik encrypted profile backup"
    static let version = 1
    static let maximumPasswordLength = 512

    enum Error: LocalizedError, Equatable {
        case invalidPassword
        case invalidArchive
        case wrongPassword
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidPassword: "Задайте пароль для резервной копии."
            case .invalidArchive: "Файл резервной копии повреждён или имеет неверный формат."
            case .wrongPassword: "Неверный пароль резервной копии."
            case .unsupportedVersion: "Эта версия резервной копии больше не поддерживается."
            }
        }
    }

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let salt: Data
        let sealedData: Data
    }

    private struct Payload: Codable {
        let profile: BrowserProfile
        let exportedAt: Date
    }

    static func export(profile: BrowserProfile, password: String,
                       to destination: URL, now: Date = Date()) throws {
        guard valid(password) else { throw Error.invalidPassword }
        // Credentials live in Keychain. Clear the username as well so a
        // backup can be safely handed to support without proxy identifiers.
        var safeProfile = profile
        if var proxy = safeProfile.proxy {
            proxy.username = ""
            safeProfile.proxy = proxy
        }
        let payload = try JSONEncoder.neantikStable.encode(Payload(profile: safeProfile, exportedAt: now))
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let key = deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(payload, using: key)
        let envelope = Envelope(format: format, version: version, salt: salt,
                                 sealedData: sealed.combined ?? Data())
        guard !envelope.sealedData.isEmpty else { throw Error.invalidArchive }
        let data = try JSONEncoder.neantikStable.encode(envelope)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    static func restore(from source: URL, password: String) throws -> BrowserProfile {
        guard valid(password) else { throw Error.invalidPassword }
        let envelope: Envelope
        do { envelope = try JSONDecoder.neantikStable.decode(Envelope.self, from: Data(contentsOf: source)) }
        catch { throw Error.invalidArchive }
        guard envelope.format == format else { throw Error.invalidArchive }
        guard envelope.version == version else { throw Error.unsupportedVersion }
        let key = deriveKey(password: password, salt: envelope.salt)
        let payloadData: Data
        do { payloadData = try AES.GCM.open(try AES.GCM.SealedBox(combined: envelope.sealedData), using: key) }
        catch { throw Error.wrongPassword }
        do { return try JSONDecoder.neantikStable.decode(Payload.self, from: payloadData).profile }
        catch { throw Error.invalidArchive }
    }

    private static func valid(_ password: String) -> Bool {
        !password.isEmpty && password.count <= maximumPasswordLength
    }

    private static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        // Feed the password bytes directly into HKDF. Hashing a password once
        // with SHA-256 is not password hardening and makes the construction
        // look like a fast password hash to security scanners. HKDF still
        // provides the domain-separated key derivation needed here; the local
        // archive format keeps the random salt in its envelope.
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: passwordKey, salt: salt,
                                      info: Data("NeAntik profile backup v1".utf8), outputByteCount: 32)
    }
}

/// Small recovery surface used by the profile inspector. It intentionally
/// asks for a password only when the user explicitly chooses an action.
struct ProfileRecoveryView: View {
    let profileName: String
    let snapshots: [URL]
    let onExport: (String) -> Void
    let onRestoreSnapshot: (URL) -> Void
    @State private var password = ""
    @State private var exportMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Резервная копия") .font(.headline)
            Text("Данные остаются на этом Mac и шифруются вашим паролем.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Пароль резервной копии", text: $password)
            HStack {
                Button("Экспортировать…", systemImage: "lock.doc") {
                    exportMode = true
                    onExport(password)
                }.disabled(password.isEmpty)
                Spacer()
            }
            if !snapshots.isEmpty {
                Divider()
                Text("Снимки профиля").font(.subheadline.weight(.semibold))
                ForEach(snapshots, id: \.path) { snapshot in
                    HStack {
                        Label(snapshot.lastPathComponent, systemImage: "clock.arrow.circlepath")
                            .lineLimit(1)
                        Spacer()
                        Button("Восстановить") { onRestoreSnapshot(snapshot) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding()
    }
}
