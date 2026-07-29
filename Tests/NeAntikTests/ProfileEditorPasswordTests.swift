import Testing
@testable import NeAntik

@Suite("ProfileEditorPasswordTests")
struct ProfileEditorPasswordTests {
    @Test
    func keepsExistingPasswordAfterKeychainReadFailure() {
        #expect(
            ProxyPasswordUpdate.resolve(
                currentHasUsername: true,
                originalHadUsername: true,
                enteredPassword: "",
                originalPassword: nil,
                readFailed: true
            ) == .keepExisting
        )
    }

    @Test
    func replacesPasswordEnteredAfterKeychainReadFailure() {
        #expect(
            ProxyPasswordUpdate.resolve(
                currentHasUsername: true,
                originalHadUsername: true,
                enteredPassword: "new secret",
                originalPassword: nil,
                readFailed: true
            ) == .replace("new secret")
        )
    }

    @Test
    func deletesPasswordWhenAuthenticationIsRemoved() {
        #expect(
            ProxyPasswordUpdate.resolve(
                currentHasUsername: false,
                originalHadUsername: true,
                enteredPassword: "",
                originalPassword: "old secret",
                readFailed: true
            ) == .delete
        )
    }

    @Test
    func unchangedLoadedPasswordDoesNotRewriteKeychain() {
        #expect(
            ProxyPasswordUpdate.resolve(
                currentHasUsername: true,
                originalHadUsername: true,
                enteredPassword: "same secret",
                originalPassword: "same secret",
                readFailed: false
            ) == .keepExisting
        )
    }
}
