#!/usr/bin/env python3

"""Apply NeAntik's coherent Apple Silicon device-tuple overlay."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import sys


FILES = {
    "components/ungoogled/fingerprint_data.h": {
        "before": "5f9ccd4608415ce391d1f9966beda49334a4ddbbfa0762c1faab53201ebc1899",
        "after": "ac8fd05d120b2664f523db64bade5222e5a5d97df65b93d642833626a5e82e09",
        "transform": "fingerprint_data",
    },
    "third_party/blink/renderer/modules/webgl/gpu_fingerprint.cc": {
        "before": "41d3d6a8d744406a107f4798be31adc92f090ed966321fa1ae66cae7c2c700f6",
        "after": "4066d30220a81d729cd9e798ad7956ad1f238c0e61522b1162272d5525fd1671",
        "transform": "gpu",
    },
    "third_party/blink/renderer/core/frame/navigator_concurrent_hardware.cc": {
        "before": "078da3d5eeb92cd6e5d3637d93959e8fd50541475926b8b3fd9fdfc71200ce37",
        "after": "e7791c3f40971b5330ab352476b4f34254c5ca066d843665a1b62ed3f9e76867",
        "transform": "hardware",
    },
    "third_party/blink/renderer/core/frame/navigator_device_memory.cc": {
        "before": "c512efd8150eaed420acac0d82c2e2a6cd219493397afc9d6687435136eb95ac",
        "after": "02d619bb22b4de4c2271ed0554ad3bfad60027ca050700149714634ec523c02a",
        "transform": "memory",
    },
    "third_party/blink/common/user_agent/user_agent_metadata.cc": {
        "before": "6079957cb4386c4f3855f556b0bc8f090ba3c5ae976ca6b53376483f42dbff90",
        "legacy_after": "efbf39b88411e87848163a1a8425dd817f4a1ca5a108868f440395ea08687827",
        "after": "b1ebf0c6bcb69b80d1f6f8badbf68e14f04581c9968afa2ae536fb4b80dcaa8b",
        "transform": "user_agent",
    },
    "third_party/blink/renderer/core/frame/screen.cc": {
        "before": "88785f6efc1a9aa1aefd057fd6fa7e7ba716d528446e03761e112c38b0f24c3d",
        "after": "96ec24fb4a9622225f2ba559524d2c88cd0f25cf969dadd73b3b9060010d72be",
        "transform": "screen",
    },
    "third_party/blink/renderer/core/frame/local_dom_window.cc": {
        "before": "1831599f8637a601ae1acf46c5ed08b74cf30cceb31d9bfc7a280cd7d9cc11ec",
        "legacy_after": "7aa718094c8d7f25871206c79a1d116154c292e448094bbb96bfb4f913e7791b",
        "after": "8aba17992e2590e6163938db2678e628741ed1b742b2dcacab22b83f97e5fc91",
        "transform": "scale",
    },
}


TUPLE_CATALOG = """

// Reviewed, internally coherent Apple Silicon device profiles. All
// browser-visible hardware values must be selected from the same row.
struct MacOSDeviceTuple {
  size_t gpu_model_index;
  unsigned hardware_concurrency;
  unsigned physical_memory_gb;
  float web_device_memory_gb;
  int screen_width;
  int screen_height;
  int available_width;
  int available_height;
  double device_scale_factor;
  const char* platform_version;
};

constexpr MacOSDeviceTuple kMacOSDeviceTuples[] = {
    {0, 8, 8, 8.0f, 1280, 800, 1280, 775, 2.0, "15.5.0"},
    {1, 10, 16, 8.0f, 1512, 982, 1512, 957, 2.0, "15.4.1"},
    {2, 8, 8, 8.0f, 1280, 832, 1280, 807, 2.0, "15.4.0"},
    {3, 12, 32, 8.0f, 1728, 1117, 1728, 1092, 2.0, "15.3.2"},
    {4, 12, 16, 8.0f, 1512, 982, 1512, 957, 2.0, "15.3.1"},
    {5, 8, 8, 8.0f, 1280, 832, 1280, 807, 2.0, "15.3.0"},
    {6, 16, 36, 8.0f, 1728, 1117, 1728, 1092, 2.0, "15.2.0"},
    {7, 12, 18, 8.0f, 1512, 982, 1512, 957, 2.0, "15.1.1"},
    {8, 10, 16, 8.0f, 1280, 832, 1280, 807, 2.0, "15.1.0"},
    {9, 16, 36, 8.0f, 1728, 1117, 1728, 1092, 2.0, "15.0.1"},
    {10, 14, 24, 8.0f, 1512, 982, 1512, 957, 2.0, "15.5.0"},
};

constexpr size_t kMacOSDeviceTupleCount =
    sizeof(kMacOSDeviceTuples) / sizeof(kMacOSDeviceTuples[0]);
static_assert(kMacOSDeviceTupleCount == kMacosGpuModelCount);

constexpr const MacOSDeviceTuple& GetMacOSDeviceTuple(uint32_t fingerprint) {
  return kMacOSDeviceTuples[fingerprint % kMacOSDeviceTupleCount];
}
"""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def replace_once(text: str, before: str, after: str) -> str:
    if text.count(before) != 1:
        raise ValueError(f"expected one exact preimage, found {text.count(before)}")
    return text.replace(before, after, 1)


def transform_fingerprint_data(text: str) -> str:
    text = replace_once(
        text,
        "#define COMPONENTS_UNGOOGLED_FINGERPRINT_DATA_H_\n",
        "#define COMPONENTS_UNGOOGLED_FINGERPRINT_DATA_H_\n\n"
        "#include <cstddef>\n#include <cstdint>\n",
    )
    anchor = (
        "constexpr size_t kMacosGpuModelCount = "
        "sizeof(kMacosGpuModels) / sizeof(kMacosGpuModels[0]);"
    )
    return replace_once(text, anchor, anchor + TUPLE_CATALOG)


def transform_gpu(text: str) -> str:
    text = replace_once(
        text,
        "using ungoogled::fingerprint::kMacosGpuModelCount;\n\n",
        "",
    )
    return replace_once(
        text,
        "    // Use helper function to get macOS GPU string\n"
        "    return GetMacosGpuString(fingerprint % kMacosGpuModelCount);",
        "    const auto& device =\n"
        "        ungoogled::fingerprint::GetMacOSDeviceTuple(fingerprint);\n"
        "    return GetMacosGpuString(device.gpu_model_index);",
    )


def transform_hardware(text: str) -> str:
    text = replace_once(
        text,
        '#include "base/command_line.h"\n#include "base/system/sys_info.h"\n',
        '#include "base/command_line.h"\n'
        '#include "base/strings/string_number_conversions.h"\n'
        '#include "base/strings/string_util.h"\n'
        '#include "base/system/sys_info.h"\n'
        '#include "components/ungoogled/fingerprint_data.h"\n',
    )
    anchor = (
        "  if (command_line->HasSwitch(switches::kFingerprint)) {\n"
        "    std::string fingerprint_str = "
        "command_line->GetSwitchValueASCII(switches::kFingerprint);"
    )
    block = (
        "  if (command_line->HasSwitch(::switches::kFingerprint) &&\n"
        "      command_line->HasSwitch(::switches::kFingerprintPlatform) &&\n"
        "      base::EqualsCaseInsensitiveASCII(\n"
        "          command_line->GetSwitchValueASCII("
        "::switches::kFingerprintPlatform),\n"
        '          "macos")) {\n'
        "    uint32_t fingerprint = 0;\n"
        "    if (base::StringToUint(\n"
        "            command_line->GetSwitchValueASCII(::switches::kFingerprint),\n"
        "            &fingerprint)) {\n"
        "      return ungoogled::fingerprint::GetMacOSDeviceTuple(fingerprint)\n"
        "          .hardware_concurrency;\n"
        "    }\n"
        "  }\n\n"
    )
    return replace_once(text, anchor, block + anchor)


def transform_memory(text: str) -> str:
    text = replace_once(
        text,
        '#include "third_party/blink/renderer/core/frame/navigator_device_memory.h"\n',
        '#include "third_party/blink/renderer/core/frame/navigator_device_memory.h"\n\n'
        '#include "base/command_line.h"\n'
        '#include "base/strings/string_number_conversions.h"\n'
        '#include "base/strings/string_util.h"\n'
        '#include "components/ungoogled/fingerprint_data.h"\n'
        '#include "components/ungoogled/ungoogled_switches.h"\n',
    )
    return replace_once(
        text,
        "float NavigatorDeviceMemory::deviceMemory() const {\n  return 8;",
        "float NavigatorDeviceMemory::deviceMemory() const {\n"
        "  const base::CommandLine* command_line = "
        "base::CommandLine::ForCurrentProcess();\n"
        "  if (command_line->HasSwitch(switches::kFingerprint) &&\n"
        "      command_line->HasSwitch(switches::kFingerprintPlatform) &&\n"
        "      base::EqualsCaseInsensitiveASCII(\n"
        "          command_line->GetSwitchValueASCII("
        "switches::kFingerprintPlatform),\n"
        '          "macos")) {\n'
        "    uint32_t fingerprint = 0;\n"
        "    if (base::StringToUint(\n"
        "            command_line->GetSwitchValueASCII(switches::kFingerprint),\n"
        "            &fingerprint)) {\n"
        "      return ungoogled::fingerprint::GetMacOSDeviceTuple(fingerprint)\n"
        "          .web_device_memory_gb;\n"
        "    }\n"
        "  }\n"
        "  return 8;",
    )


def transform_user_agent(text: str) -> str:
    text = replace_once(
        text,
        "    return kMacOSVersions[seed % std::size(kMacOSVersions)];",
        "    return GetMacOSDeviceTuple(static_cast<uint32_t>(seed))"
        ".platform_version;",
    )
    return replace_once(
        text,
        "  // 3. Check if has fingerprint seed\n"
        "  if (command_line->HasSwitch(switches::kFingerprint)) {\n"
        "    int seed = 0;\n"
        "    base::StringToInt(\n"
        "        command_line->GetSwitchValueASCII(switches::kFingerprint), "
        "&seed);\n"
        "    return kChromiumVersions[seed % std::size(kChromiumVersions)];\n"
        "  }\n\n"
        "  // 4. Return first version\n"
        "  return kChromiumVersions[0];",
        "  // Keep Client Hints on the exact compiled Chromium version. A profile\n"
        "  // seed must never make the runtime claim a different browser build.\n"
        "  return kChromiumVersions[0];",
    )


def transform_screen(text: str) -> str:
    text = replace_once(
        text,
        '#include "base/numerics/safe_conversions.h"\n',
        '#include "base/command_line.h"\n'
        '#include "base/numerics/safe_conversions.h"\n'
        '#include "base/strings/string_number_conversions.h"\n'
        '#include "base/strings/string_util.h"\n'
        '#include "components/ungoogled/fingerprint_data.h"\n'
        '#include "components/ungoogled/ungoogled_switches.h"\n',
    )
    helper = """
namespace {

const ungoogled::fingerprint::MacOSDeviceTuple*
GetMacOSDeviceTupleForCurrentProcess() {
  const base::CommandLine* command_line = base::CommandLine::ForCurrentProcess();
  if (!command_line->HasSwitch(switches::kFingerprint) ||
      !command_line->HasSwitch(switches::kFingerprintPlatform) ||
      !base::EqualsCaseInsensitiveASCII(
          command_line->GetSwitchValueASCII(switches::kFingerprintPlatform),
          "macos")) {
    return nullptr;
  }
  uint32_t fingerprint = 0;
  if (!base::StringToUint(
          command_line->GetSwitchValueASCII(switches::kFingerprint),
          &fingerprint)) {
    return nullptr;
  }
  return &ungoogled::fingerprint::GetMacOSDeviceTuple(fingerprint);
}

}  // namespace

"""
    text = replace_once(text, "namespace blink {\n\n", "namespace blink {\n\n" + helper)
    return replace_once(
        text,
        "  if (!DomWindow())\n    return gfx::Rect();\n"
        "  LocalFrame* frame = DomWindow()->GetFrame();",
        "  if (!DomWindow())\n    return gfx::Rect();\n"
        "  if (const auto* device = GetMacOSDeviceTupleForCurrentProcess()) {\n"
        "    return gfx::Rect(\n"
        "        0, 0, available ? device->available_width : device->screen_width,\n"
        "        available ? device->available_height : device->screen_height);\n"
        "  }\n"
        "  LocalFrame* frame = DomWindow()->GetFrame();",
    )


def transform_scale(text: str) -> str:
    text = replace_once(
        text,
        '#include "base/metrics/histogram_macros.h"\n',
        '#include "base/metrics/histogram_macros.h"\n'
        '#include "base/strings/string_number_conversions.h"\n'
        '#include "base/strings/string_util.h"\n',
    )
    text = replace_once(
        text,
        '#include "cc/input/snap_selection_strategy.h"\n',
        '#include "cc/input/snap_selection_strategy.h"\n'
        '#include "components/ungoogled/fingerprint_data.h"\n'
        '#include "components/ungoogled/ungoogled_switches.h"\n',
    )
    anchor = "  return GetFrame()->DevicePixelRatio();"
    block = (
        "  const base::CommandLine* command_line = "
        "base::CommandLine::ForCurrentProcess();\n"
        "  if (command_line->HasSwitch(switches::kFingerprint) &&\n"
        "      command_line->HasSwitch(switches::kFingerprintPlatform) &&\n"
        "      base::EqualsCaseInsensitiveASCII(\n"
        "          command_line->GetSwitchValueASCII("
        "switches::kFingerprintPlatform),\n"
        '          "macos")) {\n'
        "    uint32_t fingerprint = 0;\n"
        "    if (base::StringToUint(\n"
        "            command_line->GetSwitchValueASCII(switches::kFingerprint),\n"
        "            &fingerprint)) {\n"
        "      return ungoogled::fingerprint::GetMacOSDeviceTuple(fingerprint)\n"
        "          .device_scale_factor;\n"
        "    }\n"
        "  }\n\n"
    )
    return replace_once(text, anchor, block + anchor)


TRANSFORMS = {
    "fingerprint_data": transform_fingerprint_data,
    "gpu": transform_gpu,
    "hardware": transform_hardware,
    "memory": transform_memory,
    "user_agent": transform_user_agent,
    "screen": transform_screen,
    "scale": transform_scale,
}


def migrate_user_agent(text: str) -> str:
    return replace_once(
        text,
        "  // 3. Check if has fingerprint seed\n"
        "  if (command_line->HasSwitch(switches::kFingerprint)) {\n"
        "    int seed = 0;\n"
        "    base::StringToInt(\n"
        "        command_line->GetSwitchValueASCII(switches::kFingerprint), "
        "&seed);\n"
        "    return kChromiumVersions[seed % std::size(kChromiumVersions)];\n"
        "  }\n\n"
        "  // 4. Return first version\n"
        "  return kChromiumVersions[0];",
        "  // Keep Client Hints on the exact compiled Chromium version. A profile\n"
        "  // seed must never make the runtime claim a different browser build.\n"
        "  return kChromiumVersions[0];",
    )


def migrate_scale(text: str) -> str:
    return text.replace(
        "switches::kFingerprint", "::switches::kFingerprint"
    )


MIGRATIONS = {
    "user_agent": migrate_user_agent,
    "scale": migrate_scale,
}


def replace_atomically(path: Path, data: bytes) -> None:
    temporary = path.with_name(f".{path.name}.nevision-device-tuples")
    temporary.write_bytes(data)
    os.chmod(temporary, path.stat().st_mode)
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--print-post-hashes", action="store_true")
    arguments = parser.parse_args()
    root = arguments.source_root.resolve()

    for relative, expectation in FILES.items():
        path = root / relative
        if not path.is_file():
            print(f"Missing Chromium source file: {path}", file=sys.stderr)
            return 66
        original = path.read_bytes()
        actual = digest(original)
        if expectation["after"] and actual == expectation["after"]:
            print(f"OK   {relative}")
            continue
        legacy_after = expectation.get("legacy_after")
        if legacy_after and actual == legacy_after:
            updated = MIGRATIONS[expectation["transform"]](
                original.decode("utf-8")
            ).encode("utf-8")
            updated_digest = digest(updated)
            if arguments.print_post_hashes:
                print(f'"{relative}": "{updated_digest}",')
                continue
            if expectation["after"] != updated_digest:
                print(
                    f"Unexpected migrated postimage for {relative}: "
                    f"{updated_digest}",
                    file=sys.stderr,
                )
                return 65
            if arguments.check:
                print(
                    f"Device tuple overlay needs migration: {relative}",
                    file=sys.stderr,
                )
                return 65
            replace_atomically(path, updated)
            print(f"MIGRATE {relative}")
            continue
        if actual != expectation["before"]:
            print(
                f"Unexpected preimage for {relative}: {actual}",
                file=sys.stderr,
            )
            return 65
        try:
            updated = TRANSFORMS[expectation["transform"]](
                original.decode("utf-8")
            ).encode("utf-8")
        except ValueError as error:
            print(f"Cannot transform {relative}: {error}", file=sys.stderr)
            return 65
        updated_digest = digest(updated)
        if arguments.print_post_hashes:
            print(f'"{relative}": "{updated_digest}",')
            continue
        if expectation["after"] != updated_digest:
            print(
                f"Unexpected postimage for {relative}: {updated_digest}",
                file=sys.stderr,
            )
            return 65
        if arguments.check:
            print(f"Device tuple overlay is not applied: {relative}", file=sys.stderr)
            return 65
        replace_atomically(path, updated)
        print(f"APPLY {relative}")

    print("NeAntik coherent Apple device tuple overlay verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
