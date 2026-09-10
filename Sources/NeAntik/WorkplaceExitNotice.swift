/// A local, transient recovery hint. Profile association stays in the manager;
/// the privacy-safe BrowserExitEvent diagnostic format remains unchanged.
struct WorkplaceExitNotice: Equatable, Sendable {
    let message: String

    static func resolve(
        classification: BrowserExitClassification,
        wasForceStopped: Bool
    ) -> Self? {
        // Startup failures already have a launch alert. A user-requested force
        // stop is classified as a crash diagnostically, but is not unexpected.
        guard classification == .crashOrSignal, !wasForceStopped else {
            return nil
        }
        return Self(message:
            "Браузер неожиданно завершился. Открой рабочее место снова, чтобы продолжить."
        )
    }
}
