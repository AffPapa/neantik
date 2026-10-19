import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ApplicationUpdateSheetTests {
    @Test func latestReleaseLinkUsesGitHubLatestRoute() {
        let url = ApplicationUpdateSheet.latestReleaseURL
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.path == "/AffPapa/neantik/releases/latest")
    }
}
