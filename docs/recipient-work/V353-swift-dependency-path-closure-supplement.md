# V353: V135 Swift dependency path-to-source closure supplement

Status: **observed compile-input paths and Ninja provenance mapped for the retained V135 tree; not an independent recipient build, legal clearance, final-candidate qualification, or release PASS**.

The source offer V288 remains frozen at manifest SHA-256 `73b83130fc540e65dc238f6fe510e831654b39a93fb691690de1532335ebcc42`. The mapping is bound to WebKit source archive SHA-256 `658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f`, source commit `43d5b8d85e2e5eed41d7ff8a79da831bf405be6c`, both recorded source patches, V135 build receipt `a491a638ee081d08e330a7a100fb4c738361b066be5bcdb7226b1bc19132ecb4`, and Ninja graph SHA-256 `2a28e27f417390a2f24e8dfe28b5e094e30eee2b22aae165cfbeba308dd38836`.

For the 11,415 literal paths in 106 retained `.swiftdeps` records:

- 6,077 build-tree symlinks resolve directly into the pinned WebKit source tree.
- 73 build-tree symlinks resolve to generated outputs; all 73 have Ninja `CUSTOM_COMMAND` edges with source inputs.
- Of 308 regular build-tree files, 87 match pinned source bytes exactly. The 46 with no individual Ninja output edge are all among those exact source matches.
- The other 221 regular paths have recorded Ninja input edges (220 `CUSTOM_COMMAND`, one Swift compiler module rule). Their inputs, together with the 73 generated-output edges, name 2,807 unique source-tree paths; all 2,807 exist in the exact V135 extraction. The edges bind the generator scripts, IDL/message inputs, templates, and source files needed for these observed paths.
- The records also name Xcode 27.0 / Swift 6.4 / macOS SDK 27.0 host files. These remain external toolchain prerequisites, not source-offer components.

Receipts V348, V351, and V352 carry the normalized path list, per-`.swiftdeps` hashes, and exact Ninja query records. This closes the provenance map for the observed Swift-dependency paths in the retained build graph. It does not prove that every generator was independently replayed, that another recipient can reproduce or load a signed replacement, or that all image/resource notice applicability is resolved. Preserve V288 unchanged; add this supplement only to a detached revision, then validate its complete manifest and run the source-offer consumer preflight on that revision.
