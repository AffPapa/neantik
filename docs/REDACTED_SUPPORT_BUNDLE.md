# Redacted support bundle

NeAntik support export must be a small, local, privacy-safe status snapshot.
It is not a copy of BrowserData and must never contain raw fingerprint captures,
profile names or IDs, cookies, credentials, proxy endpoints, IP addresses,
ICE candidates, URLs, local paths, process arguments, page content or free-form
user text.

## Contract

The exact JSON contract is verified by:

```sh
python3 scripts/verify-redacted-support-bundle.py bundle.json
```

The root has only these fields:

- `schemaVersion` and UTC `generatedAt`;
- manager version/build;
- runtime status, version, `arm64`/`unknown` architecture, signature and
  optional SHA-256 executable/framework digests;
- bounded aggregate workspace and health counts;
- allowlisted check IDs with bounded statuses;
- manager/runtime performance statuses.

There are no free-form strings in the contract. This makes accidental export
of a path, URL, profile identity, proxy value or raw browser observation fail
closed at validation time. The Swift UI integration remains a separate step:
it must construct this allowlisted object directly from typed snapshots rather
than serializing an existing workspace or fingerprint report.

The bundle is useful for diagnosing release and manager health while preserving
the boundary between owner-only raw evidence and a shareable support summary.
