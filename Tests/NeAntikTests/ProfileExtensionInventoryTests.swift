import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProfileExtensionInventoryTests {
    private let firstID = String(repeating: "a", count: 32)
    private let secondID = String(repeating: "b", count: 32)

    @Test func packagedLocalizedNameIsReadableWithoutOpeningBrowser() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var value = entry(); value["location"] = 1
        var manifest = value["manifest"] as! [String: Any]
        manifest["name"] = "__MSG_ExtensionName__"; manifest["default_locale"] = "en_US"
        value["manifest"] = manifest
        try preferences(root, records: [firstID: value])
        let messages = root.appendingPathComponent("Default/Extensions/\(firstID)/1.0_0/_locales/en_US/messages.json")
        try FileManager.default.createDirectory(at: messages.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["extensionname": ["message": "Local fixture name"]]).write(to: messages)
        let record = try #require(try ProfileExtensionInventory.scan(browserData: root).records.first)
        #expect(record.name == "Local fixture name")
        #expect(!record.metadataNeedsBrowser)
        #expect(record.state == .unknown) // Resolving a label never proves enabled state.
        #expect(record.nameLocale == "en_US")
    }

    @Test(arguments: ["missing", "badJSON", "caseCollision", "placeholder", "unsafeText", "unsafeLocale", "externalPath", "unpacked", "ambiguousVersion"])
    func uncertainLocaleMetadataKeepsExplicitFallback(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var value = localizedEntry()
        if kind == "unsafeLocale" {
            var manifest = value["manifest"] as! [String: Any]; manifest["default_locale"] = "../../external"; value["manifest"] = manifest
        }
        if kind == "externalPath" { value["path"] = "/private/tmp/not-an-installed-extension" }
        if kind == "unpacked" { value["location"] = 4 }
        try preferences(root, records: [firstID: value])
        let messages = try localeFile(root)
        switch kind {
        case "missing": break
        case "badJSON": try Data("{".utf8).write(to: messages)
        case "caseCollision": try JSONSerialization.data(withJSONObject: ["name": ["message": "one"], "NAME": ["message": "two"]]).write(to: messages)
        case "placeholder": try localeMessages("$product$", to: messages)
        case "unsafeText": try localeMessages("name\nsecond line", to: messages)
        default: try localeMessages("Synthetic name", to: messages)
        }
        if kind == "ambiguousVersion" {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Default/Extensions/\(firstID)/1.0_1"), withIntermediateDirectories: false)
        }
        let record = try #require(try ProfileExtensionInventory.scan(browserData: root).records.first)
        #expect(record.name == "Расширение aaaaaaaa" && record.metadataNeedsBrowser)
        #expect(record.nameLocale == nil && record.state == .unknown)
    }

    @Test(arguments: ["fileSymlink", "fileHardlink", "localeSymlink", "oversize"])
    func unsafeLocaleFilesAreNotRead(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try preferences(root, records: [firstID: localizedEntry()])
        let messages = try localeFile(root)
        let outside = root.appendingPathComponent("protected")
        let protected = Data("do not read or change".utf8); try protected.write(to: outside)
        switch kind {
        case "fileSymlink": try FileManager.default.createSymbolicLink(at: messages, withDestinationURL: outside)
        case "fileHardlink": try FileManager.default.linkItem(at: outside, to: messages)
        case "localeSymlink":
            try FileManager.default.removeItem(at: messages.deletingLastPathComponent())
            try FileManager.default.createSymbolicLink(at: messages.deletingLastPathComponent(), withDestinationURL: root)
        default: try Data(repeating: 0, count: ProfileExtensionInventory.maximumLocaleBytes + 1).write(to: messages)
        }
        #expect(throws: kind == "oversize" ? ProfileExtensionInventoryError.limitExceeded : .unsafeEntry) {
            try ProfileExtensionInventory.scan(browserData: root)
        }
        #expect(try Data(contentsOf: outside) == protected)
    }

    @Test(arguments: ["fileChanged", "fileReplaced", "localeMoved", "missingFileAppears"])
    func changedLocaleCannotPublishStaleLabel(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try preferences(root, records: [firstID: localizedEntry()])
        let messages = try localeFile(root)
        if kind != "missingFileAppears" { try localeMessages("Initial label", to: messages) }
        #expect(throws: ProfileExtensionInventoryError.changed) {
            try ProfileExtensionInventory.scan(browserData: root, beforeValidation: {
                switch kind {
                case "fileReplaced":
                    try FileManager.default.removeItem(at: messages)
                    try self.localeMessages("Replacement label", to: messages)
                case "localeMoved":
                    try FileManager.default.moveItem(at: messages.deletingLastPathComponent(),
                        to: messages.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("moved"))
                default: try self.localeMessages("Different label", to: messages)
                }
            })
        }
    }

    @Test func localeBudgetBoundsWholeInventory() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var records: [String: Any] = [:]
        let alphabet = Array("abcdefghijklmnop")
        for index in 0..<35 {
            let id = String(repeating: "a", count: 30) + String(alphabet[index / 16]) + String(alphabet[index % 16])
            records[id] = localizedEntry()
            let file = try localeFile(root, id: id)
            let data = try JSONSerialization.data(withJSONObject: ["name": ["message": "Synthetic label"], "padding": String(repeating: "x", count: 250_000)])
            #expect(data.count < ProfileExtensionInventory.maximumLocaleBytes)
            try data.write(to: file)
        }
        try preferences(root, records: records)
        #expect(throws: ProfileExtensionInventoryError.limitExceeded) { try ProfileExtensionInventory.scan(browserData: root) }
    }

    private func localizedEntry() -> [String: Any] {
        var value = entry(); value["location"] = 1
        var manifest = value["manifest"] as! [String: Any]
        manifest["name"] = "__MSG_name__"; manifest["default_locale"] = "en_US"
        value["manifest"] = manifest; return value
    }
    private func localeFile(_ root: URL, id: String? = nil) throws -> URL {
        let file = root.appendingPathComponent("Default/Extensions/\(id ?? firstID)/1.0_0/_locales/en_US/messages.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return file
    }
    private func localeMessages(_ name: String, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: ["NAME": ["message": name]]).write(to: url)
    }

    @Test func secureOnlyUnpackedAndResidualPackagesAreDistinct() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try preferences(root, file: "Secure Preferences", records: [firstID: entry()])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default/Extensions/\(secondID)"), withIntermediateDirectories: true)
        let snapshot = try ProfileExtensionInventory.scan(browserData: root)
        #expect(snapshot.records.count == 1 && snapshot.packageCount == 1 && snapshot.preferencesPresent)
        let record = try #require(snapshot.records.first)
        #expect(record.name == "Own fixture" && record.version == "1.0" && record.manifestVersion == 3)
        #expect(record.source == .unpacked && record.state == .unknown)
        #expect(record.permissions == ["storage", "https://example.test/*"])
        #expect(record.optionalPermissions == ["tabs"])
        #expect(!record.metadataNeedsBrowser)
    }

    @Test func missingManifestNeverFollowsExternalUnpackedPath() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try preferences(root, records: [firstID: ["path": "/private/tmp/nonexistent-extension-fixture", "location": 4]])
        let record = try #require(try ProfileExtensionInventory.scan(browserData: root).records.first)
        #expect(record.name == "Расширение aaaaaaaa" && record.version == nil && record.permissions.isEmpty)
        #expect(record.metadataNeedsBrowser && record.state == .unknown)
    }

    @Test(arguments: ["state", "empty", "reasons", "localized", "conflict", "malformedReasons"])
    func statesAndUnresolvedNamesDoNotInventEnabledState(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var record = entry()
        if kind == "state" { record["state"] = 1 }
        if kind == "empty" { record["disable_reasons"] = [] as [Int] }
        if kind == "reasons" { record["disable_reasons"] = [1, 2] }
        if kind == "malformedReasons" { record["disable_reasons"] = [0, -1] }
        if kind == "localized" {
            var manifest = record["manifest"] as! [String: Any]; manifest["name"] = "__MSG_extensionName__"; record["manifest"] = manifest
        }
        try preferences(root, records: [firstID: record])
        if kind == "conflict" {
            var secure = entry(); secure["disable_reasons"] = [1]
            try preferences(root, file: "Secure Preferences", records: [firstID: secure])
        }
        let actual = try #require(try ProfileExtensionInventory.scan(browserData: root).records.first)
        #expect(actual.state == (kind == "reasons" ? .disabled : .unknown))
        #expect(actual.conflictingMetadata == (kind == "conflict"))
        #expect(actual.metadataNeedsBrowser == (kind == "localized"))
    }

    @Test func identicalDuplicatedRecordsAreNotConflictAndInvalidIDsAreOmitted() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try preferences(root, records: [firstID: entry(), "../traversal": entry()])
        try preferences(root, file: "Secure Preferences", records: [firstID: entry()])
        let snapshot = try ProfileExtensionInventory.scan(browserData: root)
        #expect(snapshot.omittedRecords == 1 && snapshot.records.count == 1)
        #expect(snapshot.records.first?.conflictingMetadata == false)
    }

    @Test func internalComponentsAreNotPresentedAsUserExtensions() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var component = entry(); component["location"] = 5
        var externalComponent = entry(); externalComponent["location"] = 10
        try preferences(root, records: [firstID: component, secondID: externalComponent])
        #expect(try ProfileExtensionInventory.scan(browserData: root).records.isEmpty)
        try preferences(root, file: "Secure Preferences", records: [firstID: entry()])
        let record = try #require(try ProfileExtensionInventory.scan(browserData: root).records.first)
        #expect(record.conflictingMetadata && record.source == .unknown && record.state == .unknown)
    }

    @Test(arguments: ["symlink", "hardlink", "fifo", "defaultSymlink", "packagesSymlink"])
    func unsafeEntriesRefuseWithoutChangingSource(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external")
        let bytes = Data("owned synthetic protected data".utf8)
        try bytes.write(to: external)
        let destination = root.appendingPathComponent("Default/Preferences")
        if kind == "symlink" { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: external) }
        if kind == "hardlink" { try FileManager.default.linkItem(at: external, to: destination) }
        if kind == "fifo" { #expect(mkfifo(destination.path, 0o600) == 0) }
        if kind == "defaultSymlink" {
            try FileManager.default.removeItem(at: root.appendingPathComponent("Default"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Default"), withDestinationURL: root)
        }
        if kind == "packagesSymlink" {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Default/Extensions"), withDestinationURL: root)
        }
        #expect(throws: ProfileExtensionInventoryError.unsafeEntry) { try ProfileExtensionInventory.scan(browserData: root) }
        #expect(try Data(contentsOf: external) == bytes)
    }

    @Test(arguments: ["invalidJSON", "array", "wrongSettings", "permissions", "oversize", "recordLimit"])
    func malformedOrOversizedMetadataRefuses(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Default/Preferences")
        switch kind {
        case "invalidJSON": try Data("{".utf8).write(to: url)
        case "array": try Data("[]".utf8).write(to: url)
        case "wrongSettings": try Data("{\"extensions\":{\"settings\":[]}}".utf8).write(to: url)
        case "permissions":
            var value = entry(); var manifest = value["manifest"] as! [String: Any]
            manifest["permissions"] = ["unsafe\ntext"]; value["manifest"] = manifest
            try preferences(root, records: [firstID: value])
        case "oversize": try Data(repeating: 0, count: ProfileExtensionInventory.maximumPreferencesBytes + 1).write(to: url)
        default: try preferences(root, records: Dictionary(uniqueKeysWithValues: (0...256).map { ("invalid\($0)", entry()) }))
        }
        #expect(throws: ProfileExtensionInventoryError.self) { try ProfileExtensionInventory.scan(browserData: root) }
    }

    @Test func supportedPreferencesOverFramingLimitReadInChunks() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let document: [String: Any] = ["extensions": ["settings": [firstID: entry()]], "unrelated": String(repeating: "x", count: 2_000_000)]
        try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("Default/Preferences"))
        #expect(try ProfileExtensionInventory.scan(browserData: root).records.count == 1)
    }

    @Test func booleansAreNotNumericMetadataAndDiskDirectoryIsNotInstallSource() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default/Extensions/\(firstID)"), withIntermediateDirectories: true)
        try preferences(root, records: [firstID: ["manifest": ["name": "Own", "manifest_version": true], "location": true, "disable_reasons": [true]], secondID: [:]])
        let records = try ProfileExtensionInventory.scan(browserData: root).records
        #expect(records.allSatisfy { $0.state == .unknown && $0.source == .unknown && $0.manifestVersion == nil })
    }

    @Test func presentPackageInventoryMutationRejectsEvenWhenDefaultUnchanged() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let packages = root.appendingPathComponent("Default/Extensions")
        try FileManager.default.createDirectory(at: packages.appendingPathComponent(firstID), withIntermediateDirectories: true)
        #expect(throws: ProfileExtensionInventoryError.changed) {
            try ProfileExtensionInventory.scan(browserData: root, beforeValidation: {
                try FileManager.default.createDirectory(at: packages.appendingPathComponent(self.secondID), withIntermediateDirectories: false)
            })
        }
    }

    @Test(arguments: ["changed", "replaced", "addedSecure", "packages", "defaultMoved"])
    func mutationAfterCaptureCannotPublishMixedSnapshot(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try preferences(root, records: [firstID: entry()])
        #expect(throws: (any Error).self) {
            try ProfileExtensionInventory.scan(browserData: root, beforeValidation: {
                switch kind {
                case "changed": try self.preferences(root, records: [secondID: self.entry()])
                case "replaced":
                    try FileManager.default.removeItem(at: root.appendingPathComponent("Default/Preferences"))
                    try self.preferences(root, records: [self.firstID: self.entry()])
                case "addedSecure": try self.preferences(root, file: "Secure Preferences", records: [self.secondID: self.entry()])
                case "packages": try FileManager.default.createDirectory(at: root.appendingPathComponent("Default/Extensions/\(self.secondID)"), withIntermediateDirectories: true)
                default: try FileManager.default.moveItem(at: root.appendingPathComponent("Default"), to: root.appendingPathComponent("Moved"))
                }
            })
        }
    }

    @Test func emptyProfileAndCancellationAreExplicit() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try ProfileExtensionInventory.scan(browserData: root).records.isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ProfileExtensionInventory.scan(browserData: root)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func entry() -> [String: Any] {
        ["location": 4, "manifest": ["name": "Own fixture", "version": "1.0", "manifest_version": 3,
            "permissions": ["storage"], "host_permissions": ["https://example.test/*"], "optional_permissions": ["tabs"]]]
    }
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-extension-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default"), withIntermediateDirectories: true)
        return root
    }
    private func preferences(_ root: URL, file: String = "Preferences", records: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: ["extensions": ["settings": records]], options: [.sortedKeys])
            .write(to: root.appendingPathComponent("Default/\(file)"))
    }
}
