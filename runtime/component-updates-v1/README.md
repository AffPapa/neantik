# Component update completion

This is an additive **successor source patch**, not a change to published
0.8.20 (132). The current runtime deliberately blocks component requests.

## Confirmed defect

The applied ungoogled `block-requests.patch` inserts an unconditional return
at the beginning of `UpdateCheckerImpl::CheckForUpdates`. It returns before
saving or calling the completion callback. A foreground check therefore
cannot report its result or finish through the normal update-engine path.

A headed test on the downloaded 132 runtime reached the CRLSet button but
observed no component request and no persisted check result. This is evidence
of the disabled path, **not** a successful CUP refusal or a verified proxy
route. Changing scheduler delays or endpoint flags cannot remove that return.

## Change

The patch keeps component network requests disabled. It stores the callback
and uses the existing asynchronous failure helper to report
`kUpdateCheck / UNSUPPORTED_OPERATION` (5 / -10014), with no result and no retry
delay. The return remains before cache enumeration and request construction.
The existing engine preserves that category/code. No new network dependency,
command-line override, certificate exception, installer or updater is added.

The two added parameterized tests cover foreground and background calls:

- asynchronous completion exactly once and three successive calls;
- persisted error tuple and zero intercepted requests;
- completion after destroying the checker;
- finite `RunUntilIdle` controls: the old silent return fails assertions
  rather than hanging the test indefinitely.

## Qualification boundary

`manifest.json` pins the old source contract, original privacy patch,
patch bytes and both full source pre/postimages. Exact forward/reverse apply
and compilation of both changed translation units passed on an owned copy.
The build source, original build output, signed app and release assets were
not changed. Compilation does **not** mean these C++ tests were executed.

Before delivery, integrate this patch after the pinned privacy patch into a
new source/runtime contract, execute the bounded C++ tests (including the old
silent-return negative), then verify the actual headed error/settled state,
queue completion and no component request on the exact successor candidate.
The current native activation failure must remain in the evidence history.
The remaining background/DNS/UDP/route work is still separate.

## License

The affected files retain Chromium's BSD-style license notices. New patch
contributions in this directory are BSD-3-Clause; see `LICENSE`. The original
ungoogled privacy patch and all historical contracts remain unchanged.
