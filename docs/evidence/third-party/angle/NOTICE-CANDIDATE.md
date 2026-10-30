# ANGLE notice candidate — not a release notice bundle

Pinned WebKit source: `43d5b8d85e2e5eed41d7ff8a79da831bf405be6c`.

This candidate follows the exact retained ARM64 Release Ninja graph for
`libANGLE-shared.dylib`: 344 direct compile inputs, no static archive inputs,
and two mapped nested vendored sources. The main ANGLE project license covers
the ANGLE source tree; the nested sources require their own notices.

- ANGLE project license: [`ANGLE-LICENSE-43d5b8d85e2e5eed41d7ff8a79da831bf405be6c`](ANGLE-LICENSE-43d5b8d85e2e5eed41d7ff8a79da831bf405be6c)
  - upstream path `Source/ThirdParty/ANGLE/LICENSE`
  - Git blob `0f65fd60fd68d465a2283378849f16532f5ee4f1`
  - SHA-256 `bf4da21bd20bcfb5b60b7ecc67fa864a79be049e21d6178076887f178dd6c71a`
- xxHash notice: [`xxhash-LICENSE-e4c5da7234eca7baad9a46f0b144e49ccad2e500`](xxhash-LICENSE-e4c5da7234eca7baad9a46f0b144e49ccad2e500)
  - source `Source/ThirdParty/ANGLE/src/common/third_party/xxhash/xxhash.c`
  - license Git blob `e4c5da7234eca7baad9a46f0b144e49ccad2e500`
  - SHA-256 `6ffedbc0f7878612d2b23589f1ff2ab15633e1df7963a5d9fc750ec5500c7e7a`
- Chromium zlib wrapper notice: [`Chromium LICENSE at the pinned DEPS commit`](../chromium/LICENSE-738956cca47a264e92106fdbefdc040ee7ed487d)
  - source `Source/ThirdParty/ANGLE/third_party/zlib/google/compression_utils_portable.cc`
  - Chromium revision `738956cca47a264e92106fdbefdc040ee7ed487d`
  - Git blob `2249a28657f86c645f8978b75babc1bd52aca318`
  - SHA-256 `368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b`

Scope is conservative at compile-input level. This is evidence preparation only:
it does not resolve final loaded-image/resource closure, make a legal
conclusion, or authorize redistribution. The WebKit runtime remains untrusted
and unpublished.
