import IsolationQAHostSupport

// Compile separately: macOS may use executable UUIDs in network identity.
@main enum Main {
    @MainActor static func main() {
        IsolationQAHostApplication.run(expectedIdentifier: "app.neantik.desktop.network-qa.control")
    }
}
