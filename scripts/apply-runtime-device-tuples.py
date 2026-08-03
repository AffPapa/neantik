#!/usr/bin/env python3

"""Apply NeAntik's coherent Apple Silicon device-tuple overlay."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, NamedTuple


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOG_PATH = PROJECT_ROOT / "runtime" / "apple-device-tuples.json"


class DeviceTuple(NamedTuple):
    id: str
    gpu_model: str
    hardware_concurrency: int
    physical_memory_gb: int
    web_device_memory_gb: int
    screen_width: int
    screen_height: int
    available_width: int
    available_height: int
    color_depth: int
    device_scale_factor: int
    platform_version: str


class DeviceTupleCatalogError(ValueError):
    pass


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


TUPLE_CATALOG_HEADER = """

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
"""

TUPLE_CATALOG_FOOTER = """};

constexpr size_t kMacOSDeviceTupleCount =
    sizeof(kMacOSDeviceTuples) / sizeof(kMacOSDeviceTuples[0]);
static_assert(kMacOSDeviceTupleCount == kMacosGpuModelCount);

constexpr const MacOSDeviceTuple& GetMacOSDeviceTuple(uint32_t fingerprint) {
  return kMacOSDeviceTuples[fingerprint % kMacOSDeviceTupleCount];
}
"""


def positive_int(value: Any, *, field: str, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise DeviceTupleCatalogError(
            f"{label}.{field} must be a positive integer"
        )
    return value


def parse_catalog_tuple(value: Any, *, index: int) -> DeviceTuple:
    label = f"tuples[{index}]"
    if not isinstance(value, dict):
        raise DeviceTupleCatalogError(f"{label} must be an object")
    required = {
        "id",
        "gpuModel",
        "hardwareConcurrency",
        "physicalMemoryGB",
        "webDeviceMemoryGB",
        "screen",
        "deviceScaleFactor",
        "platformVersion",
    }
    if set(value) != required:
        missing = sorted(required - set(value))
        extra = sorted(set(value) - required)
        raise DeviceTupleCatalogError(
            f"{label} fields drifted; missing={missing}, extra={extra}"
        )

    tuple_id = value["id"]
    gpu_model = value["gpuModel"]
    platform_version = value["platformVersion"]
    if not isinstance(tuple_id, str) or not re.fullmatch(
        r"[a-z0-9-]+", tuple_id
    ):
        raise DeviceTupleCatalogError(f"{label}.id is invalid")
    if not isinstance(gpu_model, str) or not re.fullmatch(
        r"M[1-9](?: Pro| Max)?", gpu_model
    ):
        raise DeviceTupleCatalogError(f"{label}.gpuModel is invalid")
    if not isinstance(platform_version, str) or not re.fullmatch(
        r"15\.\d+\.\d+", platform_version
    ):
        raise DeviceTupleCatalogError(
            f"{label}.platformVersion is invalid"
        )

    screen = value["screen"]
    if not isinstance(screen, str):
        raise DeviceTupleCatalogError(f"{label}.screen is invalid")
    screen_match = re.fullmatch(
        r"(\d+)x(\d+)x(\d+)x(\d+)x(\d+)x(\d+)",
        screen,
    )
    if screen_match is None:
        raise DeviceTupleCatalogError(f"{label}.screen is invalid")
    (
        screen_width,
        screen_height,
        available_width,
        available_height,
        color_depth,
        screen_scale_factor,
    ) = (int(part) for part in screen_match.groups())

    hardware_concurrency = positive_int(
        value["hardwareConcurrency"],
        field="hardwareConcurrency",
        label=label,
    )
    physical_memory_gb = positive_int(
        value["physicalMemoryGB"],
        field="physicalMemoryGB",
        label=label,
    )
    web_device_memory_gb = positive_int(
        value["webDeviceMemoryGB"],
        field="webDeviceMemoryGB",
        label=label,
    )
    device_scale_factor = positive_int(
        value["deviceScaleFactor"],
        field="deviceScaleFactor",
        label=label,
    )
    if not 4 <= hardware_concurrency <= 32:
        raise DeviceTupleCatalogError(
            f"{label}.hardwareConcurrency is outside the reviewed range"
        )
    if physical_memory_gb < web_device_memory_gb:
        raise DeviceTupleCatalogError(
            f"{label}.physicalMemoryGB cannot be below webDeviceMemoryGB"
        )
    if web_device_memory_gb not in {4, 8}:
        raise DeviceTupleCatalogError(
            f"{label}.webDeviceMemoryGB is not a browser cohort"
        )
    if available_width != screen_width or available_height > screen_height:
        raise DeviceTupleCatalogError(
            f"{label}.screen available bounds are incoherent"
        )
    if color_depth != 24:
        raise DeviceTupleCatalogError(
            f"{label}.screen color depth must be the reviewed 24-bit cohort"
        )
    if device_scale_factor != screen_scale_factor:
        raise DeviceTupleCatalogError(
            f"{label}.deviceScaleFactor disagrees with screen"
        )

    return DeviceTuple(
        id=tuple_id,
        gpu_model=gpu_model,
        hardware_concurrency=hardware_concurrency,
        physical_memory_gb=physical_memory_gb,
        web_device_memory_gb=web_device_memory_gb,
        screen_width=screen_width,
        screen_height=screen_height,
        available_width=available_width,
        available_height=available_height,
        color_depth=color_depth,
        device_scale_factor=device_scale_factor,
        platform_version=platform_version,
    )


def load_device_tuples(path: Path) -> list[DeviceTuple]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DeviceTupleCatalogError(
            f"cannot read device tuple catalog: {path}"
        ) from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise DeviceTupleCatalogError(
            "device tuple catalog schemaVersion must be 1"
        )
    if set(payload) != {"schemaVersion", "purpose", "boundary", "tuples"}:
        raise DeviceTupleCatalogError(
            "device tuple catalog top-level fields drifted"
        )
    raw_tuples = payload.get("tuples")
    if not isinstance(raw_tuples, list) or len(raw_tuples) < 8:
        raise DeviceTupleCatalogError(
            "device tuple catalog must contain reviewed cohorts"
        )
    tuples = [
        parse_catalog_tuple(value, index=index)
        for index, value in enumerate(raw_tuples)
    ]
    ids = [item.id for item in tuples]
    gpu_models = [item.gpu_model for item in tuples]
    if len(ids) != len(set(ids)):
        raise DeviceTupleCatalogError(
            "device tuple catalog contains duplicate ids"
        )
    if len(gpu_models) != len(set(gpu_models)):
        raise DeviceTupleCatalogError(
            "device tuple catalog contains duplicate GPU cohorts"
        )
    return tuples


def render_tuple_catalog(tuples: list[DeviceTuple]) -> str:
    rows = []
    for index, item in enumerate(tuples):
        rows.append(
            "    "
            f"{{{index}, {item.hardware_concurrency}, "
            f"{item.physical_memory_gb}, "
            f"{item.web_device_memory_gb}.0f, "
            f"{item.screen_width}, {item.screen_height}, "
            f"{item.available_width}, {item.available_height}, "
            f"{item.device_scale_factor}.0, "
            f'"{item.platform_version}"}},'
        )
    return TUPLE_CATALOG_HEADER + "\n".join(rows) + "\n" + TUPLE_CATALOG_FOOTER


TUPLE_CATALOG = render_tuple_catalog(
    load_device_tuples(DEFAULT_CATALOG_PATH)
)
EXPECTED_GENERATED_CATALOG_SHA256 = (
    "befbf471657fad5d9b7d7d817a7b42d742d04a41a63368bc0c9531276484d2aa"
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def replace_once(text: str, before: str, after: str) -> str:
    if text.count(before) != 1:
        raise ValueError(f"expected one exact preimage, found {text.count(before)}")
    return text.replace(before, after, 1)


def transform_fingerprint_data(
    text: str,
    tuple_catalog: str = TUPLE_CATALOG,
) -> str:
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
    return replace_once(text, anchor, anchor + tuple_catalog)


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
    parser.add_argument(
        "--catalog",
        type=Path,
        default=DEFAULT_CATALOG_PATH,
    )
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--print-post-hashes", action="store_true")
    arguments = parser.parse_args()
    root = arguments.source_root.resolve()
    try:
        tuple_catalog = render_tuple_catalog(
            load_device_tuples(arguments.catalog.resolve())
        )
    except DeviceTupleCatalogError as error:
        print(f"Invalid Apple device tuple catalog: {error}", file=sys.stderr)
        return 65
    catalog_digest = digest(tuple_catalog.encode("utf-8"))
    if catalog_digest != EXPECTED_GENERATED_CATALOG_SHA256:
        print(
            "Generated Apple device tuple catalog has not been reviewed: "
            f"{catalog_digest}",
            file=sys.stderr,
        )
        return 65
    transforms = dict(TRANSFORMS)
    transforms["fingerprint_data"] = lambda text: transform_fingerprint_data(
        text,
        tuple_catalog,
    )

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
            updated = transforms[expectation["transform"]](
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
