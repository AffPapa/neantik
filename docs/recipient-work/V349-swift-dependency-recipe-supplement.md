# V349: Swift compile-time dependency supplement for V288

Status: **private recipe supplement draft; V288 remains frozen and source closure is not yet qualified**.

## Exact input basis

- V288 source-offer manifest SHA-256: `73b83130fc540e65dc238f6fe510e831654b39a93fb691690de1532335ebcc42`.
- WebKit source archive SHA-256: `658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f`, upstream commit `43d5b8d85e2e5eed41d7ff8a79da831bf405be6c`.
- Production Ninja graph SHA-256: `2a28e27f417390a2f24e8dfe28b5e094e30eee2b22aae165cfbeba308dd38836`; clean relocated build receipt V135 SHA-256 `a491a638ee081d08e330a7a100fb4c738361b066be5bcdb7226b1bc19132ecb4`.
- Swift toolchain observed: Xcode 27.0 build 27A5228h, Swift 6.4 / swift-driver 1.168.5, ARM64; macOS SDK 27.0, deployment target 15.4.

## Existing compiler-dependency records

The retained build contains 106 `.swiftdeps` records (117,353,072 bytes) outside `Tools/TestWebKitAPI`. Their literal absolute path strings normalize to 11,415 unique entries: 811 under pinned source, 6,458 under generated build output, 4,098 under SDK 27, 46 under the Xcode toolchain, and 2 under the Xcode macOS platform's Swift macro-plugin directory. Every extracted path existed at observation and none was unclassified. Full path list, per-record hashes, and path-set digest are bound in `docs/evidence/neantik-v348-v135-existing-swiftdeps-path-manifest-20261028.json`.

V346 separately mapped the six explicit `-external-plugin-path` flags to `Tools/TestWebKitAPI`; V348 also observes `libObservationMacros.dylib` and `libSwiftMacros.dylib` among the actual production Swift dependency records. Treat Xcode 27.0's SDK, Swift toolchain, platform files, and these macro libraries as host prerequisites. Do not misclassify the testing plugin as a runtime dependency, and do not omit the two observed Swift macro libraries from the toolchain prerequisite description.

## Reproduction and limits

A recipient should build from a fresh extraction of the exact V288-pinned source archive, apply the exact main and V36 patches in recorded order, use the recorded Xcode/SDK/Swift/ARM64/deployment settings, and request only the 14 inventoried runtime outputs. The emitted `.swiftdeps` files can then be compared against the normalized V348 path inventory. Do not copy or modify the retained V135 build tree as a substitute for a clean recipient build.

This is evidence of the literal paths present in retained compiler dependency records, not a license applicability decision, a proof that every generated build path has a complete reproducible generator recipe, a new recipient build, signed replacement/load, or release qualification. Before incorporating this supplement, map the 6,458 generated-build paths to source/generator inputs using the existing V288 crosswalk and generator records, then run the source-offer consumer preflight against a detached revision. The V288 offer and its manifest must remain unchanged.
