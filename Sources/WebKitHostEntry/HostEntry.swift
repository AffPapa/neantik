import Darwin

/// Separate executable image with no SwiftUI App lifecycle.
@main
enum NeAntikWebKitHostEntry {
    @MainActor
    static func main() {
#if NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
        fputs("NEANTIK_WEBKIT_PROXY_DIAGNOSTIC\n", stderr)
#elseif NEANTIK_WEBKIT_PROXY_QUALIFICATION
        fputs("NEANTIK_WEBKIT_PROXY_QUALIFICATION\n", stderr)
#endif
        guard CommandLine.arguments.count == 2,
              CommandLine.arguments[1] == "--neantik-webkit-host-child-v1" else {
            Darwin.exit(EX_USAGE)
        }
        WebKitHostChildRuntime.runAndExit()
    }
}
