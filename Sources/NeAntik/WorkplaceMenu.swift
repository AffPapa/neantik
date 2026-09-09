import AppKit
import SwiftUI

/// In-process UI intent only. There is no URL scheme, listener or write API.
@MainActor
final class WorkplaceNavigation: ObservableObject {
    enum Destination: Equatable { case home, create, open(UUID) }
    struct Request: Equatable {
        let id = UUID()
        let destination: Destination
    }
    @Published private(set) var pending: Request?
    @Published var isBlocked = false

    func request(_ destination: Destination) {
        guard !isBlocked else { return }
        pending = Request(destination: destination)
    }

    func consume() -> Destination? {
        defer { pending = nil }
        guard !isBlocked else { return nil }
        return pending?.destination
    }
}

struct WorkplaceMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: ProfileStore
    @ObservedObject var processes: BrowserProcessManager
    @ObservedObject var navigation: WorkplaceNavigation

    private var places: [BrowserProfile] {
        WorkplaceHomeProjection.resolve(profiles: store.profiles, search: "", limit: 8).profiles
    }

    var body: some View {
        Button("Рабочие места…") { request(.home) }
        Button("Создать рабочее место…") { request(.create) }
        if !places.isEmpty {
            Divider()
            ForEach(places) { profile in
                Button {
                    guard !navigation.isBlocked else { return }
                    let state = processes.processState(for: profile.id)
                    if state == .managed || state == .externalVerified {
                        if !processes.focus(profileID: profile.id) { request(.home) }
                    } else {
                        request(.open(profile.id))
                    }
                } label: {
                    Label(profile.name, systemImage: processes.processState(for: profile.id).isRunning
                          ? "macwindow" : "arrow.up.right")
                }
            }
        }
    }

    private func request(_ destination: WorkplaceNavigation.Destination) {
        guard !navigation.isBlocked else { return }
        navigation.request(destination)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct WorkplaceMenuLabel: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var processes: BrowserProcessManager
    @State private var activeName: String?

    var body: some View {
        Text(activeName.map { String($0.prefix(22)) + " · NeAntik" } ?? "NeAntik")
            .accessibilityLabel(activeName.map { "Рабочее место: " + $0 } ?? "Рабочие места NeAntik")
            .onAppear { refresh() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didActivateApplicationNotification
            )) { _ in refresh() }
            .onChange(of: processes.processStateRevision) { _, _ in refresh() }
            .onChange(of: store.profileListRevision) { _, _ in refresh() }
    }

    private func refresh() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let id = processes.verifiedProfileID(forProcessID: pid)
        else { activeName = nil; return }
        activeName = store.profile(withID: id)?.name
    }
}
