import SwiftUI

extension ContentView {
    var telemetryProxyCount: Int {
        store.profiles.filter { $0.proxy != nil }.count
    }

    func recordTelemetrySnapshot() {
        UserDefaults.standard.set(store.profiles.count, forKey: "telemetry.profileCount")
        telemetry.record(.snapshot, profileCount: store.profiles.count, proxyProfileCount: telemetryProxyCount)
    }

    func recordTelemetryProfileChanges() {
        let current = store.profiles.count
        let previous = UserDefaults.standard.integer(forKey: "telemetry.profileCount")
        if current > previous {
            for _ in 0..<(current - previous) {
                telemetry.record(.profileCreated, profileCount: current, proxyProfileCount: telemetryProxyCount)
            }
        }
        UserDefaults.standard.set(current, forKey: "telemetry.profileCount")
        recordTelemetrySnapshot()
    }
}
