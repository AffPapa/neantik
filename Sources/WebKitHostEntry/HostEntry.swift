import Darwin

/// Separate executable image with no SwiftUI App lifecycle.
@main
enum NeAntikWebKitHostEntry {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 2,
              CommandLine.arguments[1] == "--neantik-webkit-host-child-v1" else {
            Darwin.exit(EX_USAGE)
        }
        WebKitHostChildRuntime.runAndExit()
    }
}
