// Copyright (c) 2026 NeAntik Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "components/ungoogled/nevision_fingerprint.h"

#include <limits>
#include <optional>
#include <string>
#include <string_view>

#include "base/environment.h"
#include "base/hash/hash.h"
#include "base/strings/string_number_conversions.h"

namespace ungoogled::nevision {

namespace {

constexpr uint32_t kMaximumRuntimeSeed =
    static_cast<uint32_t>(std::numeric_limits<int32_t>::max());

std::optional<uint32_t> ReadSeedFromEnvironment() {
  std::optional<std::string> value =
      base::Environment::Create()->GetVar("NEANTIK_PROFILE_SEED");
  if (!value) {
    return std::nullopt;
  }

  uint32_t seed = 0;
  if (!base::StringToUint(*value, &seed)) {
    return std::nullopt;
  }
  if (seed == 0 || seed > kMaximumRuntimeSeed) {
    return std::nullopt;
  }
  return seed;
}

const std::optional<uint32_t>& CachedProfileSeed() {
  // The manager fixes the child environment before Process.run(). Reading it
  // once avoids an environment lookup for every deterministic audio sample or
  // pixel while keeping one stable value for the lifetime of this process.
  static const std::optional<uint32_t> seed = ReadSeedFromEnvironment();
  return seed;
}

uint32_t SaltedProfileHash(uint32_t seed, std::string_view salt) {
  return base::PersistentHash(base::NumberToString(seed) + ":" +
                              std::string(salt));
}

}  // namespace

std::optional<uint32_t> GetProfileSeed() {
  return CachedProfileSeed();
}

std::optional<double> GetProfileUnitInterval(std::string_view salt) {
  std::optional<uint32_t> seed = GetProfileSeed();
  if (!seed) {
    return std::nullopt;
  }
  return static_cast<double>(SaltedProfileHash(*seed, salt)) /
         static_cast<double>(std::numeric_limits<uint32_t>::max());
}

uint8_t GetProfileByte(std::string_view salt,
                       uint32_t index,
                       uint8_t exclusive_max) {
  if (exclusive_max == 0) {
    return 0;
  }
  std::optional<uint32_t> seed = GetProfileSeed();
  if (!seed) {
    return 0;
  }
  uint32_t hash = SaltedProfileHash(
      *seed, std::string(salt) + ":" + base::NumberToString(index));
  return static_cast<uint8_t>(hash % exclusive_max);
}

}  // namespace ungoogled::nevision
