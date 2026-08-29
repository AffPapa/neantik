import Testing
@testable import NeAntik

struct ProfileEditorValidationTests {
    private func firstIssue(
        name: String = "Работа",
        tags: [String] = ["qa"],
        note: String = "",
        startURL: String = "https://example.com",
        usesProxy: Bool = false,
        proxyKind: ProxyKind = .http,
        proxyHost: String = "127.0.0.1",
        proxyPort: String = "8080",
        proxyUsername: String = "",
        proxyPassword: String = ""
    ) -> ProfileEditorValidationIssue? {
        ProfileEditorValidation.firstIssue(
            name: name,
            tags: tags,
            note: note,
            startURL: startURL,
            usesProxy: usesProxy,
            proxyKind: proxyKind,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            proxyUsername: proxyUsername,
            proxyPassword: proxyPassword
        )
    }

    @Test
    func validDraftHasNoIssue() {
        #expect(firstIssue() == nil)
        #expect(firstIssue(usesProxy: true) == nil)
    }

    @Test
    func returnsFirstIssueInVisualFormOrder() {
        #expect(
            firstIssue(
                name: " ",
                startURL: "not a url",
                usesProxy: true,
                proxyHost: "",
                proxyPort: "0"
            )?.field == .name
        )
        #expect(
            firstIssue(
                note: String(
                    repeating: "З",
                    count: BrowserProfile.maximumNoteLength + 1
                ),
                startURL: "not a url",
                usesProxy: true,
                proxyHost: "",
                proxyPort: "0"
            )?.field == .note
        )
        #expect(
            firstIssue(
                startURL: "not a url",
                usesProxy: true,
                proxyHost: "",
                proxyPort: "0"
            )?.field == .startURL
        )
        #expect(
            firstIssue(
                usesProxy: true,
                proxyHost: "",
                proxyPort: "0"
            )?.field == .proxyHost
        )
        #expect(
            firstIssue(
                usesProxy: true,
                proxyPort: "65536"
            )?.field == .proxyPort
        )
    }

    @Test
    func proxyIsNotValidatedWhenDisabled() {
        #expect(
            firstIssue(
                usesProxy: false,
                proxyHost: "",
                proxyPort: "not a port"
            ) == nil
        )
    }

    @Test
    func noteAcceptsMultilineTextWithinBothLimits() {
        #expect(
            firstIssue(note: "Клиент: север\nСледующий шаг: проверить заказ") == nil
        )
    }

    @Test
    func noteReportsCharacterAndByteLimitsWithoutTruncating() {
        let tooManyCharacters = String(
            repeating: "З",
            count: BrowserProfile.maximumNoteLength + 1
        )
        let tooManyBytes = String(repeating: "🇹🇭", count: 513)

        let characterIssue = firstIssue(note: tooManyCharacters)
        #expect(characterIssue?.field == .note)
        #expect(characterIssue?.message.contains("1000 символов") == true)

        let byteIssue = firstIssue(note: tooManyBytes)
        #expect(tooManyBytes.count <= BrowserProfile.maximumNoteLength)
        #expect(tooManyBytes.utf8.count > BrowserProfile.maximumNoteUTF8Bytes)
        #expect(byteIssue?.field == .note)
        #expect(byteIssue?.message.contains("4096 байт") == true)
    }

    @Test
    func issuesExplainTheConcreteRepair() {
        #expect(firstIssue(name: "")?.message == "Введи название профиля.")
        #expect(
            firstIssue(
                usesProxy: true,
                proxyPort: "0"
            )?.message == "Введи порт от 1 до 65535."
        )
    }

    @Test
    func proxyPasswordRejectsNULAndTheSharedUTF8ByteLimit() {
        func singleGrapheme(atUTF8Boundary byteCount: Int) -> String {
            "a\u{1AB0}" + String(
                repeating: "\u{301}",
                count: (byteCount - 4) / 2
            )
        }

        let nulIssue = firstIssue(
            usesProxy: true,
            proxyUsername: "operator",
            proxyPassword: "secret\0tail"
        )
        #expect(nulIssue?.field == .proxyPassword)
        #expect(nulIssue?.message.contains("нулевой") == true)

        let family = "👨‍👩‍👧‍👦"
        let legacyBoundary = String(
            repeating: family,
            count: ProxyImportParser.maximumPasswordLength
        )
        #expect(
            firstIssue(
                usesProxy: true,
                proxyUsername: "operator",
                proxyPassword: legacyBoundary
            ) == nil
        )

        let characterIssue = firstIssue(
            usesProxy: true,
            proxyUsername: "operator",
            proxyPassword: legacyBoundary + family
        )
        #expect(characterIssue?.field == .proxyPassword)
        #expect(
            characterIssue?.message.contains(
                "\(ProxyImportParser.maximumPasswordLength) символов"
            ) == true
        )

        let byteBoundary = singleGrapheme(
            atUTF8Boundary: ProxyImportParser.maximumPasswordBytes
        )
        #expect(
            firstIssue(
                usesProxy: true,
                proxyUsername: "operator",
                proxyPassword: byteBoundary
            ) == nil
        )
        let tooManyBytes = byteBoundary + "\u{301}"
        let byteIssue = firstIssue(
            usesProxy: true,
            proxyUsername: "operator",
            proxyPassword: tooManyBytes
        )
        #expect(
            tooManyBytes.utf8.count >
                ProxyImportParser.maximumPasswordBytes
        )
        #expect(byteIssue?.field == .proxyPassword)
        #expect(
            byteIssue?.message.contains(
                "\(ProxyImportParser.maximumPasswordBytes) байт"
            ) == true
        )
    }

    @Test
    func ignoredSocksPasswordDoesNotBlockSaving() {
        #expect(
            firstIssue(
                usesProxy: true,
                proxyKind: .socks5,
                proxyPassword: "secret\0tail"
            ) == nil
        )
    }
}
