# V346: Swift plugin dependency boundary for the V135 WebKit recipe

Status: **bounded input-graph observation; not dependency closure or release qualification**.

The exact V135 clean-relocated build receipt records `build.ninja` SHA-256 `2a28e27f417390a2f24e8dfe28b5e094e30eee2b22aae165cfbeba308dd38836` and the 14 requested ARM64 runtime link outputs. A read-only scan of that exact graph found six `-external-plugin-path` occurrences. Each belongs to a `Tools/TestWebKitAPI` Swift compile edge and names the Xcode `testing` plugin with `swift-plugin-server`. No `-load-plugin-executable`, `-load-plugin`, or `-plugin-library` flags occur. None of those six test targets is one of the 14 runtime link outputs.

The observed host toolchain is Xcode 27.0 build 27A5228h, Swift 6.4 / swift-driver 1.168.5, target `arm64-apple-macosx27.0.0`. The `swiftc` SHA-256 is `63f3ca45b1cc6ee81ccf2b6a11e9de3e7deeef85438915403ad5fa0bd5bccde8`; `swift-plugin-server` SHA-256 is `1fbea6364fb4586546951b404ce3e077052154035c45ca9a1304dc78476332a0`. The SDK selector is `MacOSX27.0.sdk` (a symlink to `MacOSX.sdk` in this Xcode installation).

For a production recipient build that requests only the 14 runtime targets, the testing plugin is a test-suite prerequisite, not an observed runtime-target prerequisite. If the source offer promises to run TestWebKitAPI, it must include the matching Xcode testing plugin/server as a host toolchain prerequisite. This observation narrows the plugin gap; it does not resolve implicit Swift imports, SDK modules, other host tools/libraries, corresponding-source completeness, recipient relink/load, or license applicability. Do not add this document to or mutate the hash-frozen V288 source offer without creating and verifying a new offer revision.

Reproduction: read-only inspection of the exact recorded Ninja graph, mapping every plugin flag to its preceding build edge, plus `xcrun swiftc --version` and SHA-256 of the two named executables. No compiler build, dependency scan, browser launch, package mutation, signature, or test run was performed.
