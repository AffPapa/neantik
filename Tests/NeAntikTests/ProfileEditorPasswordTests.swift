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

    @Test
    func oldTimerCannotConsumeNewClipboardLease() {
        var lease = ClipboardLeaseState()
        lease.begin(changeCount: 10)
        lease.begin(changeCount: 20)

        let oldTimerOwnedLease = lease.consumeIfOwned(
            currentChangeCount: 20,
            expectedChangeCount: 10
        )
        #expect(!oldTimerOwnedLease)
        #expect(lease.changeCount == 20)
    }

    @Test
    func userClipboardReplacementReleasesWithoutClearing() {
        var lease = ClipboardLeaseState()
        lease.begin(changeCount: 20)

        let replacementWasOwned = lease.consumeIfOwned(
            currentChangeCount: 21,
            expectedChangeCount: 20
        )
        #expect(!replacementWasOwned)
        #expect(lease.changeCount == nil)
    }

    @Test
    func matchingLeaseCanBeClearedOnce() {
        var lease = ClipboardLeaseState()
        lease.begin(changeCount: 20)

        let firstClearWasOwned = lease.consumeIfOwned(
            currentChangeCount: 20,
            expectedChangeCount: 20
        )
        let secondClearWasOwned = lease.consumeIfOwned(
            currentChangeCount: 20,
            expectedChangeCount: 20
        )
        #expect(firstClearWasOwned)
        #expect(!secondClearWasOwned)
    }

    @Test
    func cancelledLeaseCannotClearClipboard() {
        var lease = ClipboardLeaseState()
        lease.begin(changeCount: 20)
        lease.cancel()

        let cancelledLeaseWasOwned = lease.consumeIfOwned(
            currentChangeCount: 20
        )
        #expect(!cancelledLeaseWasOwned)
    }
}
