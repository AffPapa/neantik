// Copyright 2026 NeAntik Authors. SPDX-License-Identifier: MPL-2.0
#ifndef THIRD_PARTY_BLINK_RENDERER_PLATFORM_FONTS_NEANTIK_SYSTEM_GENERIC_DEFAULTS_H_
#define THIRD_PARTY_BLINK_RENDERER_PLATFORM_FONTS_NEANTIK_SYSTEM_GENERIC_DEFAULTS_H_
#include "third_party/blink/renderer/platform/platform_export.h"
namespace blink {
class GenericFontFamilySettings;
// Opt-in COMMON defaults for standalone workers; not document preferences.
PLATFORM_EXPORT void ApplySystemFontPolicyGenericDefaultsIfEmpty(
    GenericFontFamilySettings& settings);
}  // namespace blink
#endif
