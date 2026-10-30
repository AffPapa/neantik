import IsolationQAHostSupport

@main enum Main {
    @MainActor static func main() {
        IsolationQAHostApplication.run(expectedIdentifier: "app.neantik.desktop.network-qa.profilehost")
    }
}
