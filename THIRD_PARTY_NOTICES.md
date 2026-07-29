# Third-party notices

NeAntik's browser runtime is built from Chromium and macOS packaging work from
the ungoogled-chromium ecosystem. Those components are not relicensed under
MPL-2.0.

The checked-in runtime lock records the exact upstream repositories, tags,
commits, trees, and relevant hashes. The corresponding license texts are:

- [Chromium license](runtime/licenses/Chromium-LICENSE);
- [fingerprint-chromium license](runtime/licenses/fingerprint-chromium-LICENSE);
- [ungoogled-chromium-macos license](runtime/licenses/ungoogled-chromium-macos-LICENSE).

Patch files contain context derived from the projects they modify and retain
the applicable upstream notices. Redistributors must preserve all notices
generated into the packaged runtime by `scripts/generate-runtime-compliance.sh`.
