import Foundation
import Testing
@testable import NeAntik

struct ProfileDuplicationTests {
    @Test
    func defaultsToDirectWithoutPasswordAndPreservesDestination() {
        let folderID = UUID()
        let options = ProfileDuplicationOptions(
            name: "Рабочий — копия",
            destinationFolderID: folderID
        )

        #expect(options.destinationFolderID == folderID)
        #expect(!options.copiesProxy)
        #expect(!options.copiesProxyPassword)
    }

    @Test
    func passwordConsentCannotOutliveProxyConsent() {
        var options = ProfileDuplicationOptions(
            name: "Копия",
            destinationFolderID: nil,
            copiesProxy: false,
            copiesProxyPassword: true
        )

        #expect(!options.copiesProxyPassword)

        options.setCopiesProxy(true)
        options.setCopiesProxyPassword(true)
        #expect(options.copiesProxyPassword)

        options.setCopiesProxy(false)
        #expect(!options.copiesProxy)
        #expect(!options.copiesProxyPassword)
    }

    @Test
    func suggestedNameIsValidBoundedAndAvoidsExistingNames() throws {
        let sourceName = String(
            repeating: "Д",
            count: BrowserProfile.maximumNameLength
        )
        let first = try #require(
            BrowserProfile.nameByAppendingSuffix(
                " — копия",
                to: sourceName
            )
        )
        let suggested = ProfileDuplicationPolicy.suggestedName(
            for: sourceName,
            existingNames: [first.uppercased()]
        )

        #expect(BrowserProfile.isValidName(suggested))
        #expect(suggested.hasSuffix(" — копия 2"))
        #expect(suggested.count <= BrowserProfile.maximumNameLength)
    }

    @Test
    func nameValidationTrimsSafeInputAndRejectsUnsafeInput() {
        let valid = ProfileDuplicationNameValidation.resolve(
            "  Новый профиль  "
        )
        let invalid = ProfileDuplicationNameValidation.resolve(
            "Плохое\u{0000}имя"
        )

        #expect(valid.normalizedName == "Новый профиль")
        #expect(valid.message == nil)
        #expect(invalid.normalizedName == nil)
        #expect(invalid.message != nil)
    }

    @Test
    func duplicateAlwaysGetsFreshIdentityAndBrowserData() throws {
        let source = BrowserProfile(
            name: "TikTok · FR",
            colorHex: "#10B981",
            symbolName: "folder.fill",
            tags: ["TikTok", "Фарм"],
            note: "Не копировать",
            isPinned: true,
            isArchived: true,
            startURL: "https://example.com",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 8_080,
                username: "operator"
            ),
            lastLaunchedAt: Date(timeIntervalSince1970: 100)
        )
        let options = ProfileDuplicationOptions(
            name: " TikTok · FR — копия ",
            destinationFolderID: UUID()
        )
        let copy = try ProfileDuplicationPolicy.makeProfile(
            from: source,
            options: options,
            at: Date(timeIntervalSince1970: 200)
        )
        let paths = AppPaths(
            rootDirectory: URL(fileURLWithPath: "/tmp/neantik-duplicate-test")
        )

        #expect(copy.id != source.id)
        #expect(copy.identity != source.identity)
        #expect(
            paths.browserDataDirectory(for: copy.id) !=
                paths.browserDataDirectory(for: source.id)
        )
        #expect(copy.name == "TikTok · FR — копия")
        #expect(copy.colorHex == source.colorHex)
        #expect(copy.symbolName == source.symbolName)
        #expect(copy.tags == source.tags)
        #expect(copy.note.isEmpty)
        #expect(!copy.isPinned)
        #expect(!copy.isArchived)
        #expect(copy.lastLaunchedAt == nil)
        #expect(copy.proxy == nil)
        #expect(copy.createdAt == Date(timeIntervalSince1970: 200))
    }

    @Test
    func proxyAndPasswordRequireSeparateExplicitChoices() throws {
        let source = BrowserProfile(
            name: "Источник",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: "operator"
            )
        )
        var options = ProfileDuplicationOptions(
            name: "Копия",
            destinationFolderID: nil
        )

        #expect(
            !ProfileDuplicationPolicy.shouldCopyProxyPassword(
                source: source,
                options: options
            )
        )

        options.setCopiesProxy(true)
        let proxyCopy = try ProfileDuplicationPolicy.makeProfile(
            from: source,
            options: options
        )
        #expect(proxyCopy.proxy == source.proxy)
        #expect(
            !ProfileDuplicationPolicy.shouldCopyProxyPassword(
                source: source,
                options: options
            )
        )

        options.setCopiesProxyPassword(true)
        #expect(
            ProfileDuplicationPolicy.shouldCopyProxyPassword(
                source: source,
                options: options
            )
        )

        let directSource = BrowserProfile(name: "Direct")
        #expect(
            !ProfileDuplicationPolicy.shouldCopyProxyPassword(
                source: directSource,
                options: options
            )
        )
    }

    @Test
    func invalidNameCannotCreateProfile() {
        let source = BrowserProfile(name: "Источник")
        let options = ProfileDuplicationOptions(
            name: "   ",
            destinationFolderID: nil
        )

        #expect(throws: ProfileDuplicationError.invalidName) {
            try ProfileDuplicationPolicy.makeProfile(
                from: source,
                options: options
            )
        }
    }

    @Test
    func staleSourceRevisionRequiresFreshDuplicatePreview() {
        var source = BrowserProfile(name: "Источник", revision: 3)
        #expect(throws: ProfileDuplicationError.sourceChanged) {
            try ProfileDuplicationPolicy.requireCurrentSource(
                source,
                expectedRevision: 2
            )
        }

        source.revision = 4
        let currentSourceWasAccepted: Bool
        do {
            try ProfileDuplicationPolicy.requireCurrentSource(
                source,
                expectedRevision: 4
            )
            currentSourceWasAccepted = true
        } catch {
            currentSourceWasAccepted = false
        }
        #expect(currentSourceWasAccepted)
    }
}
