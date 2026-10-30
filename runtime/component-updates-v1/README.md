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

`manifest.json` preserves the initial source-only preparation: the old source
contract, original privacy patch, patch bytes and both pre/postimages. Its
historical execution fields are not rewritten after subsequent work.

The successor development runtime has now been built and signed separately.
Four actual C++ cases pass; the same tests linked against the old checker fail
all four cases. Two consecutive headed foreground operations reach the visible
error state and persist `5 / -10014 / 0`, with zero observed component requests.
Collector canaries, unknown-component control and owned-process cleanup pass.
See [development evidence](../../docs/evidence/component-completion-development.json)
and [source proof](../chromium-15612-component-completion-v1-source-proof.json).

These observations do not qualify a manager/app release or prove the proxy
route, CUP refusal, component installation, global DNS/UDP or all background
traffic. The original 132 activation failure and subsequent setup/cleanup
failures remain in the evidence history. Published 132 bytes stay unchanged.

## License

The affected files retain Chromium's BSD-style license notices. New patch
contributions in this directory are BSD-3-Clause; see `LICENSE`. The original
ungoogled privacy patch and all historical contracts remain unchanged.
