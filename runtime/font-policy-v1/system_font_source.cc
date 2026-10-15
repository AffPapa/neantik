// Copyright 2026 NeAntik Authors. SPDX-License-Identifier: MPL-2.0
#include "system_font_source.h"

#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string>
#include <set>
#include <vector>
#include <cmath>
#include <limits>
#include <sys/stat.h>
#include <unistd.h>

namespace neantik::fonts {
namespace {
template <typename T> class OwnedCF {
 public:
  explicit OwnedCF(T value) : value_(value) {}
  ~OwnedCF() { if (value_) CFRelease(value_); }
  T get() const { return value_; }
  OwnedCF(const OwnedCF&) = delete;
  OwnedCF& operator=(const OwnedCF&) = delete;
 private:
  T value_;
};

struct FileOrigin {
  Origin origin = Origin::kMissingOrInvalidURL;
  std::string canonical;
  dev_t device = 0;
  ino_t inode = 0;
};

FileOrigin InspectURL(CFTypeRef attribute) {
  FileOrigin result;
  if (!attribute || CFGetTypeID(attribute) != CFURLGetTypeID()) return result;
  auto url = static_cast<CFURLRef>(attribute);
  OwnedCF<CFStringRef> scheme(CFURLCopyScheme(url));
  if (!scheme.get() || CFStringCompare(scheme.get(), CFSTR("file"),
                                     kCFCompareCaseInsensitive) != kCFCompareEqualTo) return result;
  UInt8 requested[PATH_MAX + 1] = {};
  char canonical[PATH_MAX + 1] = {};
  if (!CFURLGetFileSystemRepresentation(url, true, requested, sizeof(requested)) ||
      !realpath(reinterpret_cast<const char*>(requested), canonical)) {
    result.origin = Origin::kUnavailableFile; return result;
  }
  result.canonical = canonical;
  int fd = open(canonical, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) { result.origin = Origin::kUnavailableFile; return result; }
  struct stat info = {};
  const bool valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode);
  close(fd);
  if (!valid) { result.origin = Origin::kUnavailableFile; return result; }
  result.device = info.st_dev; result.inode = info.st_ino;
  if (result.canonical.starts_with("/System/Library/Fonts/") && info.st_uid == 0 &&
      !(info.st_mode & (S_IWGRP | S_IWOTH))) {
    result.origin = Origin::kProtectedSystemFile;
  } else if (result.canonical.starts_with("/System/Library/AssetsV2/")) {
    result.origin = Origin::kSystemAssetCandidate;
  } else {
    result.origin = Origin::kOtherFile;
  }
  return result;
}

FileOrigin InspectFont(CTFontRef font) {
  if (!font) return {};
  OwnedCF<CFTypeRef> url(CTFontCopyAttribute(font, kCTFontURLAttribute));
  return InspectURL(url.get());
}

bool EqualTables(CTFontRef actual, CTFontRef counterpart) {
  OwnedCF<CFArrayRef> actual_tags(CTFontCopyAvailableTables(actual, kCTFontTableOptionNoOptions));
  OwnedCF<CFArrayRef> counterpart_tags(CTFontCopyAvailableTables(counterpart, kCTFontTableOptionNoOptions));
  if (!actual_tags.get() || !counterpart_tags.get() ||
      CFArrayGetCount(actual_tags.get()) == 0 ||
      CFArrayGetCount(actual_tags.get()) != CFArrayGetCount(counterpart_tags.get())) return false;
  for (CFIndex i = 0; i < CFArrayGetCount(actual_tags.get()); ++i) {
    // CoreText stores CTFontTableTag integer values directly in this array;
    // they are not CFNumber objects and must never be dereferenced as CFType.
    auto raw_tag = reinterpret_cast<uintptr_t>(CFArrayGetValueAtIndex(actual_tags.get(), i));
    if (!raw_tag || raw_tag > UINT32_MAX) return false;
    auto tag = static_cast<CTFontTableTag>(raw_tag);
    OwnedCF<CFDataRef> a(CTFontCopyTable(actual, tag, kCTFontTableOptionNoOptions));
    OwnedCF<CFDataRef> b(CTFontCopyTable(counterpart, tag, kCTFontTableOptionNoOptions));
    if (!a.get() || !b.get() || !CFEqual(a.get(), b.get())) return false;
  }
  return true;
}

bool CoversText(CTFontRef font, CFStringRef text) {
  if (!font || !text) return false;
  OwnedCF<CFStringRef> name(CTFontCopyPostScriptName(font));
  if (name.get() && (CFStringCompare(name.get(),CFSTR("LastResort"),kCFCompareCaseInsensitive)==kCFCompareEqualTo ||
                     CFStringCompare(name.get(),CFSTR(".LastResort"),kCFCompareCaseInsensitive)==kCFCompareEqualTo)) return false;
  CFIndex length = CFStringGetLength(text);
  if (length <= 0 || length > 256) return false;  // Bounded fallback request.
  std::vector<UniChar> chars(length);
  std::vector<CGGlyph> glyphs(length, 0);
  CFStringGetCharacters(text, CFRangeMake(0,length), chars.data());
  CTFontGetGlyphsForCharacters(font, chars.data(), glyphs.data(), length);
  for (CFIndex i=0; i<length; ++i) {
    // Layout controls/variation selectors are interpreted by shaping, not
    // independent glyphs. Final shaped runs still require source validation.
    if (chars[i] == 0x200C || chars[i] == 0x200D || chars[i] == 0xFE0E || chars[i] == 0xFE0F) continue;
    if (CFStringIsSurrogateLowCharacter(chars[i]) && i && CFStringIsSurrogateHighCharacter(chars[i-1])) continue;
    if (!glyphs[i]) return false;
  }
  return true;
}

double StyleDistance(CTFontRef requested, CTFontRef candidate) {
  // This is a fallback tie break, not a replacement for Blink/Skia's CSS
  // matching algorithm. Prefer the native fallback's actual family/style.
  constexpr CTFontSymbolicTraits mask = kCTFontTraitBold | kCTFontTraitItalic |
      kCTFontTraitCondensed | kCTFontTraitExpanded;
  double result = (CTFontGetSymbolicTraits(requested) & mask) ==
                  (CTFontGetSymbolicTraits(candidate) & mask) ? 0 : 100;
  OwnedCF<CFDictionaryRef> a(CTFontCopyTraits(requested));
  OwnedCF<CFDictionaryRef> b(CTFontCopyTraits(candidate));
  if (!a.get() || !b.get()) return result;
  for (auto key:{kCTFontWeightTrait,kCTFontWidthTrait,kCTFontSlantTrait}) {
    auto x=static_cast<CFNumberRef>(CFDictionaryGetValue(a.get(),key));
    auto y=static_cast<CFNumberRef>(CFDictionaryGetValue(b.get(),key));
    double xv=0,yv=0;
    if (x && y && CFGetTypeID(x)==CFNumberGetTypeID() && CFGetTypeID(y)==CFNumberGetTypeID() &&
        CFNumberGetValue(x,kCFNumberDoubleType,&xv) && CFNumberGetValue(y,kCFNumberDoubleType,&yv) &&
        std::isfinite(xv) && std::isfinite(yv)) result+=std::abs(xv-yv);
  }
  return result;
}
}  // namespace

Origin ResolvedOrigin(CTFontRef font) { return InspectFont(font).origin; }

const char* OriginLabel(Origin origin) {
  switch (origin) {
    case Origin::kProtectedSystemFile: return "protected-system-file";
    case Origin::kSystemAssetCandidate: return "OS-asset-candidate";
    case Origin::kOtherFile: return "other-file";
    case Origin::kUnavailableFile: return "unavailable-file";
    case Origin::kMissingOrInvalidURL: return "missing-or-invalid-URL";
  }
  return "invalid-origin";
}

bool MatchesProtectedSystemSource(CTFontRef font) {
  FileOrigin origin = InspectFont(font);
  if (origin.origin != Origin::kProtectedSystemFile) return false;
  OwnedCF<CFStringRef> name(CTFontCopyPostScriptName(font));
  OwnedCF<CFTypeRef> attribute(CTFontCopyAttribute(font, kCTFontURLAttribute));
  if (!name.get() || !attribute.get() || CFGetTypeID(attribute.get()) != CFURLGetTypeID()) return false;
  OwnedCF<CFArrayRef> descriptors(CTFontManagerCreateFontDescriptorsFromURL(static_cast<CFURLRef>(attribute.get())));
  if (!descriptors.get()) return false;
  for (CFIndex i = 0; i < CFArrayGetCount(descriptors.get()); ++i) {
    auto descriptor = static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(descriptors.get(), i));
    OwnedCF<CFTypeRef> candidate_name(CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute));
    if (!candidate_name.get() || !CFEqual(name.get(), candidate_name.get())) continue;
    OwnedCF<CTFontRef> counterpart(CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(font), nullptr));
    auto actual_source = InspectFont(counterpart.get());
    if (actual_source.origin == Origin::kProtectedSystemFile && actual_source.device == origin.device &&
        actual_source.inode == origin.inode && EqualTables(font, counterpart.get())) return true;
  }
  return false;
}

SystemSourcePolicy::~SystemSourcePolicy() {
  for (const auto& entry : entries_) CFRelease(entry.font);
  for (const auto& descriptor : descriptors_) CFRelease(descriptor);
}

bool SystemSourcePolicy::AllowsHostFont(CTFontRef font) {
  if (!font) return false;
  {
    std::lock_guard lock(mutex_);
    for (const auto& entry : entries_) if (entry.font == font) return entry.allowed;
  }
  const bool allowed = MatchesProtectedSystemSource(font);
  std::lock_guard lock(mutex_);
  for (const auto& entry : entries_) if (entry.font == font) return entry.allowed;
  if (entries_.size() == kMaximumEntries) { CFRelease(entries_.front().font); entries_.pop_front(); }
  CFRetain(font); entries_.push_back({font, allowed}); return allowed;
}

size_t SystemSourcePolicy::CachedCount() const {
  std::lock_guard lock(mutex_); return entries_.size();
}

void SystemSourcePolicy::LoadSystemDescriptors() {
  std::call_once(catalog_once_, [this] {
    OwnedCF<CFArrayRef> urls(CTFontManagerCopyAvailableFontURLs());
    if (!urls.get()) return;
    // Stable protected-file order prevents user inventory order from deciding
    // tie breaks in style/fallback selection. Never publish the path list.
    std::set<std::string> files;
    for (CFIndex i=0; i<CFArrayGetCount(urls.get()); ++i) {
      CFTypeRef value=CFArrayGetValueAtIndex(urls.get(),i);
      auto source=InspectURL(value);
      if (source.origin==Origin::kProtectedSystemFile) files.insert(source.canonical);
    }
    for (const auto& file:files) {
      OwnedCF<CFURLRef> url(CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
          reinterpret_cast<const UInt8*>(file.data()), file.size(), false));
      OwnedCF<CFArrayRef> faces(CTFontManagerCreateFontDescriptorsFromURL(url.get()));
      if (!faces.get()) continue;
      for (CFIndex j=0; j<CFArrayGetCount(faces.get()); ++j) {
        auto descriptor=static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(faces.get(),j));
        if (!descriptor || CFGetTypeID(descriptor)!=CTFontDescriptorGetTypeID()) continue;
        CFRetain(descriptor);descriptors_.push_back(descriptor);
      }
    }
  });
}

CFArrayRef SystemSourcePolicy::CopySystemCandidates(CFStringRef name) {
  LoadSystemDescriptors();
  CFMutableArrayRef result=CFArrayCreateMutable(kCFAllocatorDefault,0,&kCFTypeArrayCallBacks);
  if (!name || !CFStringGetLength(name)) return result;
  for (auto descriptor:descriptors_) {
    for (auto key:{kCTFontFamilyNameAttribute,kCTFontNameAttribute,kCTFontDisplayNameAttribute}) {
      OwnedCF<CFTypeRef> value(CTFontDescriptorCopyAttribute(descriptor,key));
      if (value.get() && CFGetTypeID(value.get())==CFStringGetTypeID() &&
          CFStringCompare(static_cast<CFStringRef>(value.get()),name,kCFCompareCaseInsensitive)==kCFCompareEqualTo) {
        CFArrayAppendValue(result,descriptor);break;
      }
    }
  }
  return result;
}

size_t SystemSourcePolicy::SystemDescriptorCount() {
  LoadSystemDescriptors();return descriptors_.size();
}

CFArrayRef SystemSourcePolicy::CopySystemDescriptors() {
  LoadSystemDescriptors();
  return CFArrayCreate(kCFAllocatorDefault,
      reinterpret_cast<const void**>(descriptors_.data()),
      descriptors_.size(), &kCFTypeArrayCallBacks);
}

bool SystemSourcePolicy::AllowsText(CTFontRef font, CFStringRef text) {
  return AllowsHostFont(font) && CoversText(font, text);
}

CTFontRef SystemSourcePolicy::CopySystemFallbackForText(CTFontRef base, CFStringRef text,
                                                      CFStringRef language) {
  if (!base || !text || CFStringGetLength(text)<=0 || CFStringGetLength(text)>256) return nullptr;
  OwnedCF<CTFontRef> native(CTFontCreateForStringWithLanguage(base,text,CFRangeMake(0,CFStringGetLength(text)),language));
  if (native.get() && AllowsHostFont(native.get()) && CoversText(native.get(),text)) {
    CFRetain(native.get());return native.get();
  }
  // A user font may shadow an otherwise available protected fallback family.
  // Recover the exact protected face, then that family, before changing family.
  if (native.get()) {
    for (auto key:{kCTFontNameAttribute,kCTFontFamilyNameAttribute}) {
      OwnedCF<CFStringRef> name(key==kCTFontNameAttribute
          ? CTFontCopyPostScriptName(native.get()) : CTFontCopyFamilyName(native.get()));
      if (!name.get()) continue;
      OwnedCF<CFArrayRef> candidates(CopySystemCandidates(name.get()));
      CTFontRef best=nullptr;
      double best_distance=std::numeric_limits<double>::infinity();
      for (CFIndex i=0;i<CFArrayGetCount(candidates.get());++i) {
        auto descriptor=static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(candidates.get(),i));
        CTFontRef candidate=CTFontCreateWithFontDescriptor(descriptor,CTFontGetSize(base),nullptr);
        OwnedCF<CFStringRef> actual_name(candidate ? (key==kCTFontNameAttribute
            ? CTFontCopyPostScriptName(candidate) : CTFontCopyFamilyName(candidate)) : nullptr);
        if (candidate && actual_name.get() && CFStringCompare(name.get(),actual_name.get(),kCFCompareCaseInsensitive)==kCFCompareEqualTo &&
            CoversText(candidate,text) && AllowsHostFont(candidate)) {
          const double distance=StyleDistance(native.get(),candidate);
          if (distance<best_distance) {
            if (best) CFRelease(best);
            best=candidate;candidate=nullptr;best_distance=distance;
          }
        }
        if (candidate) CFRelease(candidate);
      }
      if (best) return best;
    }
  }
  LoadSystemDescriptors();
  // Prefer native language coverage metadata, then the remaining protected
  // faces. No font from a failed/unknown source becomes an implicit fallback.
  for (bool preferred:{true,false}) {
    for (auto descriptor:descriptors_) {
      bool same_language=false;
      OwnedCF<CFTypeRef> languages(CTFontDescriptorCopyAttribute(descriptor,kCTFontLanguagesAttribute));
      if (language && languages.get() && CFGetTypeID(languages.get())==CFArrayGetTypeID()) {
        auto values=static_cast<CFArrayRef>(languages.get());
        for (CFIndex i=0; i<CFArrayGetCount(values); ++i) {
          CFTypeRef value=CFArrayGetValueAtIndex(values,i);
          if (value && CFGetTypeID(value)==CFStringGetTypeID() &&
              (CFStringHasPrefix(language,static_cast<CFStringRef>(value)) || CFStringHasPrefix(static_cast<CFStringRef>(value),language))) same_language=true;
        }
      }
      if (same_language!=preferred) continue;
      CTFontRef candidate=CTFontCreateWithFontDescriptor(descriptor,CTFontGetSize(base),nullptr);
      if (candidate && CoversText(candidate,text) && AllowsHostFont(candidate)) return candidate;
      if (candidate) CFRelease(candidate);
    }
  }
  return nullptr;
}
}  // namespace neantik::fonts
