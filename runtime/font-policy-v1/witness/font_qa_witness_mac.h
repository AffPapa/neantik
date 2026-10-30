// Copyright 2026 NeAntik Authors. SPDX-License-Identifier: MPL-2.0
#ifndef COMPONENTS_UNGOOGLED_FONT_QA_WITNESS_MAC_H_
#define COMPONENTS_UNGOOGLED_FONT_QA_WITNESS_MAC_H_
#include "base/component_export.h"
#include "base/files/file_path.h"
namespace ungoogled::nevision {
// QA-only seam. Missing request is a no-op; malformed requests fail closed.
// These are correlation/custody checks, not a permission boundary against the
// same OS user. The regular manager removes inherited NEANTIK_* variables.
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) bool FontQARequested();
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) bool PrepareFontQAProcess();
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) bool ValidateFontQAProcess();
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) bool ValidateFontQAProfile(const base::FilePath&, bool approve);
// Process-scoped, fixed bundled bytes only. Must run before default font caches.
// A timeout/error/failed native selection returns false, never an absent-font PASS.
COMPONENT_EXPORT(NEANTIK_FONT_POLICY_MAC) bool RegisterFontQAWitness();
}  // namespace ungoogled::nevision
#endif
