# Defensive checker signal matrix

This is a local QA checklist for NeAntik's own checker. It describes what we
observe and compare; it is not an evasion recipe and does not claim that any
third-party anti-fraud system can be bypassed.

## Covered by the current audit

1. Browser version and platform declaration
2. User-Agent and Client Hints agreement
3. Locale and language list
4. Timezone identifier
5. Screen width and height
6. Device pixel ratio
7. WebRTC probe completion
8. WebRTC candidate summary
9. Direct WebRTC control result
10. DNS/proxy health result
11. Proxy kind and validity
12. Canvas rendering digest
13. Repeated canvas digest stability
14. WebGL pixel digest
15. Repeated WebGL digest stability
16. WebGL vendor and renderer
17. WebGL extension set
18. WebGL shader precision
19. Worker canvas digest
20. Worker WebGL digest
21. Worker timezone
22. Worker Client Hints
23. Audio rendering digest
24. Repeated audio digest stability
25. Client-rect rendering digest
26. Repeated client-rect digest stability
27. Installed extension manifest and permissions
28. Profile revision binding
29. Profile-to-runtime evidence binding
30. Cross-profile cookie/storage isolation

## Safe follow-up checks

31. Permission state consistency for the same profile
32. Notification permission state
33. Media-device enumeration count (without device labels)
34. WebGPU availability and adapter summary
35. IndexedDB/localStorage availability
36. Service-worker registration count
37. Cache-storage namespace isolation
38. Shared-worker namespace isolation
39. Storage quota stability
40. Profile lock ownership and stale-lock recovery
41. Snapshot restore checksum
42. Clean-launch tab reset
43. Startup-tab set validity
44. Crash recovery tab replay
45. Chromium runtime compatibility marker
46. Runtime executable architecture
47. Runtime code-signing identity
48. Manager/runtime version agreement
49. Diagnostic report redaction
50. Repeatability of the complete audit

Each new signal must have four tests: normal profile, intentionally
inconsistent profile, missing observation, and repeatability across two
launches. Raw URLs, cookies, credentials, proxy endpoints and profile names
must never enter the diagnostic report.

## Added in 0.6.7

- The profile details view now includes a local storage surface inspection for
  localStorage, sessionStorage, IndexedDB, service-worker state and cache
  storage.
- The scanner reports only coarse namespace/file counts and availability. It
  never reads keys, values, origin strings, cookies, URLs or proxy material.
- Symlinked entries inside a storage area are ignored so the inspection remains
  bounded to the current profile directory.

## Added in 0.6.8

- Storage surface inspection now uses a shallow bounded pass with early stop,
  so oversized profile folders produce an explicit review status instead of
  slowing the manager.
- Extension version selection is a single-pass local directory scan; the report
  still returns only manifest-derived counts and risk labels, not manifest
  bodies or browsing state.
