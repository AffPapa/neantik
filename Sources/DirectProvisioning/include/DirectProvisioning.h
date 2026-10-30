#ifndef NEANTIK_DIRECT_PROVISIONING_H
#define NEANTIK_DIRECT_PROVISIONING_H
#include <CoreFoundation/CoreFoundation.h>
#include <Security/CMSDecoder.h>
#include <stddef.h>
#include <stdint.h>

enum { NEANTIK_PROFILE_OK = 0, NEANTIK_PROFILE_FORMAT = 1,
       NEANTIK_PROFILE_SIGNATURE = 2, NEANTIK_PROFILE_TRUST = 3,
       NEANTIK_PROFILE_POLICY_UNAVAILABLE = 4 };

/* Envelope admission only, never a signature/trust verdict. Definite DER,
 * SignedData with attached data content; reject decryption forms before CMS. */
int neantik_profile_signed_data_envelope(const uint8_t *bytes, size_t length);

CF_IMPLICIT_BRIDGING_ENABLED
/* Authenticated content only. No paths, subprocess, logs or credential APIs.
 * Exact macOS profile policy is required. Missing private policy refuses.
 * Certificate issuer/revocation network fetching is disabled; OCSP consults
 * local cached replies. Fresh revocation status is not established offline.
 * Caller still must validate grants, dates and correspondence to signed code. */
CFDataRef _Nullable neantik_profile_copy_authenticated_content(
    CFDataRef _Nonnull input, int * _Nonnull status) CF_RETURNS_RETAINED;
CF_IMPLICIT_BRIDGING_DISABLED
#endif
