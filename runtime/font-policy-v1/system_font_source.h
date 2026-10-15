// Copyright 2026 NeAntik Authors. SPDX-License-Identifier: MPL-2.0
// Development primitive, not yet wired into Chromium or a published runtime.
#ifndef NEANTIK_SYSTEM_FONT_SOURCE_H_
#define NEANTIK_SYSTEM_FONT_SOURCE_H_

#include <CoreText/CoreText.h>
#include <deque>
#include <mutex>
#include <vector>

namespace neantik::fonts {

enum class Origin {
  kProtectedSystemFile,
  kSystemAssetCandidate,  // Not trusted by this version merely for its path.
  kOtherFile,
  kMissingOrInvalidURL,
  kUnavailableFile,
};

// Reads the actual resolved CTFont, never trusts a requested family/name.
Origin ResolvedOrigin(CTFontRef font);
const char* OriginLabel(Origin origin);

// URL classification alone is insufficient: a supplied descriptor can claim a
// system URL. Compare all available SFNT tables with the exact system file face.
bool MatchesProtectedSystemSource(CTFontRef font);

// Immutable CTFont objects are retained to prevent pointer reuse; bounded FIFO.
// Callers must apply this to HOST LOOKUP only. Downloaded/embedded fonts have
// their own explicit source and must not be rejected by this host-font policy.
class SystemSourcePolicy {
 public:
  SystemSourcePolicy() = default;
  ~SystemSourcePolicy();
  SystemSourcePolicy(const SystemSourcePolicy&) = delete;
  SystemSourcePolicy& operator=(const SystemSourcePolicy&) = delete;
  bool AllowsHostFont(CTFontRef font);
  size_t CachedCount() const;
  // Owned copies from real protected file descriptors, not a global family
  // relookup that may select a user font with a colliding family/name.
  CFArrayRef CopySystemCandidates(CFStringRef family_or_face);
  CTFontRef CopySystemFallbackForText(CTFontRef base, CFStringRef text,
                                    CFStringRef language);
  size_t SystemDescriptorCount();

 private:
  struct Entry { CTFontRef font; bool allowed; };
  static constexpr size_t kMaximumEntries = 32;
  mutable std::mutex mutex_;
  std::deque<Entry> entries_;
  void LoadSystemDescriptors();
  std::once_flag catalog_once_;
  std::vector<CTFontDescriptorRef> descriptors_;
};

}  // namespace neantik::fonts
#endif
