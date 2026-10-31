// Copyright 2026 NeAntik Authors. SPDX-License-Identifier: MPL-2.0
#include "components/ungoogled/system_font_policy_mac.h"
#include "base/environment.h"
#include "base/no_destructor.h"
#include "components/ungoogled/nevision_fingerprint.h"
#include "components/ungoogled/system_font_source.h"
namespace ungoogled::nevision {
namespace {
neantik::fonts::SystemSourcePolicy& Policy() {
  static base::NoDestructor<neantik::fonts::SystemSourcePolicy> policy;
  return *policy;
}
}  // namespace
bool SystemFontPolicyV1Enabled() {
  static const bool enabled = GetProfileSeed().has_value() &&
      base::Environment::Create()->GetVar("NEANTIK_FONT_POLICY") == "system-v1";
  return enabled;
}
bool IsAllowedSystemHostFont(CTFontRef font) {
  return !SystemFontPolicyV1Enabled() || Policy().AllowsHostFont(font);
}
bool ProtectedFontCoversText(CTFontRef font, CFStringRef text) {
  return SystemFontPolicyV1Enabled() && Policy().AllowsText(font, text);
}
CFArrayRef CopyProtectedFontCandidates(CFStringRef name) {
  return Policy().CopySystemCandidates(name);
}
CFArrayRef CopyProtectedFontDescriptors() { return Policy().CopySystemDescriptors(); }
CTFontRef CopyProtectedFontFallback(CTFontRef base, CFStringRef text, CFStringRef language) {
  return Policy().CopySystemFallbackForText(base, text, language);
}
}  // namespace ungoogled::nevision
