# Contributing

Contributions that improve privacy, profile isolation, accessibility,
reliability, performance, localization, build reproducibility, or release
verification are welcome.

Before opening a pull request:

1. keep the product Apple Silicon-only and native Swift/SwiftUI;
2. do not add Electron, Intel builds, mandatory accounts, or mandatory
   telemetry;
3. do not add CAPTCHA, ban, WebDriver, automation, anti-fraud, or platform-rule
   evasion;
4. preserve migration compatibility for legacy NeVision profile and Keychain
   identifiers;
5. keep proxy credentials out of arguments, logs, tests, and fixtures;
6. run:

```bash
./scripts/verify-native-swift-tests.sh
./scripts/verify-native-swift-release.sh
python3 scripts/verify-direct-telemetry-disabled.py
python3 scripts/verify-direct-update-policy.py
python3 scripts/verify-direct-ui-localization.py
python3 scripts/verify-public-fingerprint-corpus.py
python3 scripts/verify-apple-device-tuples.py
python3 scripts/verify-nevision-patchset-manifest.py --release
python3 scripts/generate-runtime-integration-notices.py --check
python3 scripts/verify-open-source-tree.py
python3 scripts/verify-public-workflow-references.py
```

Runtime changes must include updated patch hashes, postimage hashes, tests, and
an honest description of remaining limitations. Do not weaken a gate to make a
report pass.
