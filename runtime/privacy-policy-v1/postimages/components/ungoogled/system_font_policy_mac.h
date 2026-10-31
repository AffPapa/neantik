// Copyright 2026 NeAntik Authors. SPDX-License-Identifier: MPL-2.0
#ifndef COMPONENTS_UNGOOGLED_SYSTEM_FONT_POLICY_MAC_H_
#define COMPONENTS_UNGOOGLED_SYSTEM_FONT_POLICY_MAC_H_
#include <CoreText/CoreText.h>
#include "base/component_export.h"
namespace ungoogled::nevision {
// Seed presence alone never opts existing profiles into a new font identity.
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) bool SystemFontPolicyV1Enabled();
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) bool IsAllowedSystemHostFont(CTFontRef);
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) bool ProtectedFontCoversText(CTFontRef, CFStringRef);
// Owned copies; validate every font constructed or styled from a descriptor.
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) CFArrayRef CopyProtectedFontCandidates(CFStringRef);
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) CFArrayRef CopyProtectedFontDescriptors();
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) CTFontRef CopyProtectedFontFallback(CTFontRef, CFStringRef, CFStringRef);
}  // namespace ungoogled::nevision
#endif
