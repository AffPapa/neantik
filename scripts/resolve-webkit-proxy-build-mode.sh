#!/bin/zsh

# Keep the release channel and compile-time WebKit allowlist aligned. Source
# this file from each SwiftPM build entrypoint so the exported value reaches
# the manifest evaluation.
if [[ "${NEANTIK_RELEASE_CHANNEL:-}" == "production" ]]; then
  if [[ -n "${NEANTIK_WEBKIT_PROXY_BUILD_MODE:-}" &&
        "$NEANTIK_WEBKIT_PROXY_BUILD_MODE" != "production" ]]; then
    echo "Production release channel requires NEANTIK_WEBKIT_PROXY_BUILD_MODE=production." >&2
    exit 64
  fi
  export NEANTIK_WEBKIT_PROXY_BUILD_MODE=production
elif [[ "${NEANTIK_WEBKIT_PROXY_BUILD_MODE:-}" == "production" ]]; then
  echo "Production WebKit build mode requires NEANTIK_RELEASE_CHANNEL=production." >&2
  exit 64
fi
