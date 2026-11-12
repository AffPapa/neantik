# WebKit source port review

- Base: WebKit `db6a98765ec472910f9e0737f3f96f042c616e50`.
- Historical input: V20 patch based on `43d5b8d85e2e5eed41d7ff8a79da831bf405be6c`.
- Patch: `neantik-webkit-db6a98765e-source-port.patch`.
- SHA-256: `320a4545ac7c141efb9843bb623687f50a9ead00ea99e463cf4b767896d6abaf`.

The historical and successor 30-file preimage subsets match the already fetched manifests. Synthetic commits for those subsets allowed Git to three-way merge the original V20 delta. All 25 automatic resolutions match direct patch output byte for byte. Four CMake paths required semantic merges:

- ANGLE and Inspector retain the new upstream SDK system prefix on upstream paths and override the install name to `@rpath` for the owned external macOS build.
- WebKitSwift retains the upstream move into the nested framework directory and the code signing order. Its install name follows the WebKit framework's selected install name. WritingToolsUI stays outside the owned build when Writing Tools are disabled, and Catalyst retains the exclusion from the upstream lookup.
- OptionsCocoa preserves SDK prefixes and the updated umbrella framework distinction on other targets. The external macOS branch keeps the V20 embedded-framework install names.

The only additional file is the macOS Networking sandbox. The patch removes the new explicit lookup allowance for `com.apple.BrowserEngineKit.Intermediary`. That upstream allowance supports parental-controls URL filtering. The removal changes that integration in the owned host. Native compatibility and the effective sandbox policy are unverified.

The complete 30-file patch passes whitespace checks and `git apply --check` on fresh successor preimages. Applying it produced byte-for-byte equality with the resolved merge. The extracted CMake path selection passed external macOS, internal macOS and Catalyst script-mode controls. These checks do not establish a configured build, linked dependency closure, runtime confinement or release qualification.

The source-only rebase preserved contents. The final patch records the executable bit of the entitlements script from the actual upstream Git tree.
