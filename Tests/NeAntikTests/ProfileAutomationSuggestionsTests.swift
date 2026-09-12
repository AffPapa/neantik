import Foundation
import Testing
@testable import NeAntik

struct ProfileAutomationSuggestionsTests {
    @Test func suggestionsAreLocalAndActionable() {
        let direct = BrowserProfile(name: "Direct")
        let proxied = BrowserProfile(name: "Proxy", proxy: ProxyConfiguration(kind: .http, host: "127.0.0.1", port: 8080, username: ""))
        let result = ProfileAutomationSuggestions.smartSuggestions(for: [direct, proxied])
        #expect(result.map(\.query).contains("proxy:no"))
        #expect(result.map(\.query).contains("proxy:yes"))
        #expect(result.allSatisfy { !$0.query.isEmpty && $0.count > 0 })
    }
}
