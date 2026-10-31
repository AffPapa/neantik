import Foundation
import Testing
@testable import NeAntik

struct WebKitProxyQAProfileFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_PROXY_PROFILE_FIXTURE"] != nil))
    func preseededAandBProfilesDecodeThroughProfileStore() throws {
        let raw = try #require(ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_PROXY_PROFILE_FIXTURE"])
        let url = URL(fileURLWithPath: raw, isDirectory: false)
        let profiles = try ProfileStore.decodeProfiles(Data(contentsOf: url))
        #expect(profiles.count == 2)
        let proxy = try #require(profiles.first { $0.name.hasSuffix(" A proxy") })
        let direct = try #require(profiles.first { $0.name.hasSuffix(" B direct") })
        #expect(proxy.id != direct.id)
        #expect(proxy.identity == direct.identity)
        #expect(proxy.engine == .webkit && direct.engine == .webkit)
        #expect(proxy.webKitRuntimeGeneration == .isolatedV1)
        #expect(direct.webKitRuntimeGeneration == .isolatedV1)
        #expect(proxy.startURL.hasSuffix("/proxy-a"))
        #expect(direct.startURL.hasSuffix("/direct-b"))
        #expect(proxy.proxy == ProxyConfiguration(kind: .http, host: "127.0.0.1", port: 45101, username: ""))
        #expect(direct.proxy == nil)
        #expect(proxy.normalizedForPersistence() != nil)
        #expect(direct.normalizedForPersistence() != nil)
    }
}
