# Issued-cohort capability slice

This adds one bounded headed session for each of the four issued Air cohorts
(seeds11/13/16/19). It does not replay the old11-tuple projection or the full
Canvas/WebGL/Audio/context suites. The browser is the exact downloaded135
runtime, with16 Mach-O hashes matched to its retained binding.

The own page checks WebGL1/2 limits, supported extension availability, shader
precision, repeated reads and the configured CPU/memory/screen/platform/renderer.
A one-row texture at MAX_TEXTURE_SIZE must succeed; max+1 must fail. The
65536-column guard bounds this experiment to256KiB, not a huge square texture.
A small complete framebuffer must retain a blue fill within one channel
quantum; invalid-enum and texture-size errors must remain real API errors.

Each session requires fresh normal resource admission, uses a new private
temporary profile and mock Keychain, binds a nonce to its own HTTP result,
closes normally and removes its own processes/profile. The pipe only permits
the own fixture navigation and lifecycle commands; no arbitrary page JS is
evaluated over CDP. External network requests are blocked by the local proxy
and resolver rules. The common collector code is reused unchanged.

```sh
node scripts/runtime-cohorts/test-verify.mjs
node scripts/runtime-cohorts/run-headed.mjs /absolute/runtime.app /absolute/binding.json /absolute/fresh-output 11
# Continue with13,16,19 only after the first session passes.
node scripts/runtime-cohorts/analyze.mjs /absolute/binding.json /absolute/m1 /absolute/m2 /absolute/m3 /absolute/m4
```

The offline analyzer binds exact producer/probe/runtime, admission, lifecycle
and cleanup. Each actual positive capture must reject29 deliberate defects,
including a false blue-fill claim with zero pixels and a limit inconsistent
with the allocation width. The18 modeled controls are separate unit evidence.
Raw captures and retained source inputs stay private. The public evidence
contains only canonical cohort identifiers, hashes, verdicts and limits.

These are four configured cohorts on one Mac. They do **not** prove operation
on four physical GPU models, establish a hardware capability baseline for each
model, qualify every WebGL operation or complete the1.0 release gate. The
older full-operation receipts retain their original runtime bindings.
