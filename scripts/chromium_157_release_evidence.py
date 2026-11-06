#!/usr/bin/env python3
"""Fail-closed source and build evidence for the NeAntik Chromium 157 port.

This module binds the private Mac ARM64 source tree to the exact upstream
157.0.8103.39 commit, reviewed port diff and GN args. Source evidence never
qualifies a binary or release; the build receipt must be completed separately.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any

VERSION = "157.0.8103.39"
PREFIX = "chromium-157"
CONTRACT = PREFIX + "-source-contract.json"
PLAN = PREFIX + "-rebase-plan.json"
ADOPTION = PREFIX + "-source-adoption-v1.json"
BUILD_EVIDENCE = PREFIX + "-build-evidence.json"
LOCK = "fingerprint-" + PREFIX + ".lock.json"
REPOSITORY = "https://chromium.googlesource.com/chromium/src.git"
OFFICIAL_COMMIT = "9a31f0acec1854d44e49a73fbf8017598151a583"
OFFICIAL_TREE = "e400810dee21ba266feeeef005ea83ae83fd274e"
PORT_HEAD = "95b9ebdb2192fb206f9838e1a2fbe791fbffb235"
PORT_PARENT = "39eb0679325c11436bb56ae6f3eea7bee4373322"
PORT_SOURCE_FILE_SHA256 = {'chrome/browser/autocomplete/search_provider_unittest.cc': '7dcf42f69fb6bf5563d48096d57c2ab61dc073d380ec46975343d64765e7bcc9', 'chrome/browser/browsing_data/chrome_browsing_data_remover_delegate_unittest.cc': 'c6ca4a972dc51d9216ccba016d67b40a108fbb0de1e3cacae23657123a805e8f', 'chrome/browser/download/download_item_model_unittest.cc': 'd75c93963008748da96e99c4887504e5bebbaf8332dbd0d90de1bdcc5a844e4f', 'chrome/browser/enterprise/reporting/test/test_utils.cc': 'f66711bd336c36916e3b12d99190554e9f5e80dcb7388375c440eed09b1d8b9e', 'chrome/browser/extensions/BUILD.gn': '7014558c6021cad9034c390fb14b6fe81c01c10e42a30fa26773353bdd630290', 'chrome/browser/extensions/extension_allowlist_unittest.cc': 'e1b4f65c21dbb257309683e201c87ac2529bcf59794e325f313ba5719414a13f', 'chrome/browser/extensions/extension_service.cc': 'b2864a94ab34a6710ac78957e4b85900281cb70a6d8bf903a47bd9f135936452', 'chrome/browser/extensions/extension_service_unittest.cc': 'd18613becad6a7ed71355bc7454211fca1fcdc79e662a166a245e9a3103c2fac', 'chrome/browser/media/router/discovery/mdns/dns_sd_registry_unittest.cc': '52e449c4b80788972edf24f42ca251963eab1e48576f53e1d6210e295b9f29fb', 'chrome/browser/media/router/test/mock_dns_sd_registry.cc': '5979b1b8929d4fd93dd48716cf21219440e77049c858f0c6fa67e0cdfaef0be2', 'chrome/browser/new_tab_page/one_google_bar/one_google_bar_loader_impl_unittest.cc': '8b3d8369fd0920a9fd9553d56ec647e5d066edad973aff53d23a44f042e35fca', 'chrome/browser/permissions/BUILD.gn': '828cef1016e52360bef8b5a06012d7d54844b2cbbb1f89fb0e775dd03c50b515', 'chrome/browser/profiles/chrome_browser_main_extra_parts_profiles.cc': '4c6bcdd2346d03faf7682b440a7f7dda8a581d22d3036cef54b958343f6a3f69', 'chrome/browser/resources/extensions/sidebar.ts': '6b0f08d6301e00da638ec94c54c382ce7d36ab66ec58069c89f8c51815bab5dc', 'chrome/browser/resources/settings/privacy_page/privacy_page_index.html': 'c5c6b6095a608974219ac50a0ee3a318081d00bf7cf9cf95cff8bddde2853cd8', 'chrome/browser/safe_browsing/BUILD.gn': 'ac0975ee5b18d5581b659ad569c641c7702d26347d6e90e7407f9c4cd4b9ff48', 'chrome/browser/safe_browsing/cloud_content_scanning/cloud_binary_upload_service_unittest.cc': 'b4ab1a64481f3402ddc635cd25468cdc34df6a05cd1daa5cf5d86bd4518dbe90', 'chrome/browser/search_engines/prepopulated_engines_migration_browsertest.cc': '62457d6762fca383386e4360d2296b7d357f41fb949b8436d32e3dee12161644', 'chrome/browser/search_engines/template_url_service_sync_unittest.cc': 'a8f8c0a953c6ea0bcd51e359c89800a5044a215564708c1513bb7f9d4e7a0de9', 'chrome/browser/search_engines/template_url_service_unittest.cc': 'dd6113d214b21875f73649f4256bdf9e0c6143259b5176bd08ba1d94e05af4f4', 'chrome/browser/signin/account_consistency_mode_manager_unittest.cc': 'f775efe30d234fdad95fbf19fab39365b31c3711baa69ca25d928336bc745504', 'chrome/browser/signin/chrome_signin_client.cc': '429e3ff8c10e6c97e2c0814d587324b4529bc0f722ecc9c59b1fd6458d4b2cbc', 'chrome/browser/site_protection/site_familiarity_process_selection_deferring_condition_unittest.cc': '172b43c8d78e4bb9f7ccdb340207e268aeeff660d8f93ed3c56ef290c5150788', 'chrome/browser/sync/test/integration/search_engines_helper.cc': '0a8198ed779121f66155ebc736481f2b4866f5d031c05f0ef7e5ff3c956bc495', 'chrome/browser/sync/test/integration/two_client_search_engines_sync_test.cc': '43378c8f6bdf2fb8299b9986ca56e53a1c259e0aad0363bad0d7889b00ec8d99', 'chrome/browser/ui/autofill/BUILD.gn': '0c5e5a610e17a60333c50fee63b1aa9541908197ebb5b35aba2ff725b2023060', 'chrome/browser/ui/download/download_bubble_row_view_info_unittest.cc': '4ad622439cf972c2752b05e20db311e372d8822db77f443a752cb8f240cb955a', 'chrome/browser/ui/qrcode_generator/BUILD.gn': '59d00590a8dacdb4c2cc85698a602526e929f53042fb03e65fcd7920e9c754ba', 'chrome/browser/ui/safety_hub/revoked_permissions_service_unittest.cc': '656c1194191d319ed07de667c25c72bcbbfe63265f03b3824b60f97e71b86642', 'chrome/browser/ui/search_engines/keyword_editor_controller_unittest.cc': '3afbb19a6518a6d0fed7c426d3393d8e46bcc7767f32e836ae779ee0299d834b', 'chrome/browser/ui/webui/downloads/downloads_dom_handler_unittest.cc': '5fe6dbaa2d7da2626bf95dca782994983b4ad6d995ec1d303a5f059dc8bf3517', 'chrome/browser/ui/webui/downloads/downloads_list_tracker_unittest.cc': '3d747b2a71e918bb69af29882e2fd460a8e4b0a7be6ebff21c4b4d99f897fd33', 'chrome/browser/ui/webui/settings/accessibility_main_handler_unittest.cc': '2e0117ae8415fd8d50fc969a93645ffe7a7362bbccdc1af7d712a65c8896add0', 'chrome/browser/ui/webui/side_panel/read_anything/read_anything_untrusted_page_handler.cc': '396399dbd5107ad787d3e0f5c5b560e66a5293e6bccf69dc00b5709b49804e79', 'chrome/browser/ui/webui/side_panel/read_anything/read_anything_untrusted_page_handler.h': 'dd142b2ee73baf597ed8853c5ab011fa1ff3666b94856f7042a6e72639db0082', 'chrome/browser/ui/webui/signin/turn_sync_on_helper_unittest.cc': '335579d979638f68ed0dcf346b9138454d943ead8c40f4ff363e2ea1c9f04778', 'chrome/renderer/BUILD.gn': '935c3acb7807493108711ba3d4527abcaabe6cfb889efd5962a8ecc9665c52df', 'chrome/renderer/accessibility/ax_tree_distiller.cc': 'ff7e9cb7f17095fcbad6919d967251cd844e42b510462cca2ad00e325fb1e4ea', 'chrome/renderer/accessibility/ax_tree_distiller.h': '5021c2c139119bc9f11d3cce123c97ec0e79e429e945a73046acf657a5078f5b', 'chrome/renderer/accessibility/read_anything/read_anything_app_controller_unittest.cc': '4458653221d211471a078e3bf41d6e78fb1f2f8ddbd653f2b201e5a3d4ddb6c5', 'chrome/renderer/accessibility/read_anything/read_anything_app_model_unittest.cc': '70da1e117f4d9b88eacb6a12c5bbe4878f740f33d241afeb8f134f48cf7250eb', 'chrome/renderer/accessibility/read_anything/read_anything_node_utils.cc': '3c9572cb81f1ec313094a2567fb20f77344b6949f8d19dca9223083a9132e3ba', 'chrome/renderer/accessibility/read_anything/read_anything_node_utils_unittest.cc': '5ed161c1f5660a103d52aa2a6f26b7714538be1ec43b8c74ec46f03061d69d9b', 'chrome/test/data/webui/history/history_routing_test.ts': 'c6d0b011c92585b96581063ae1fe41317dade546b95c16820332cef34238a07f', 'chrome/test/data/webui/settings/about_page_test.ts': 'd05d2fdcbbf983e9fba03446e8a6f799854f6d1f60bb8d310052315f5543c128', 'chrome/test/data/webui/settings/payments_page_test.ts': '2cabf735f10d833af75160392769a93d43d3c24068014b2ea678f92bd68bfb0d', 'chrome/test/data/webui/settings/personalization_options_test.ts': '6399df3807a119b5a5d5489fef09ce4e9ecbf7f2fd2a0ad125cca842bcf38222', 'chrome/test/data/webui/settings/test_search_engines_browser_proxy.ts': '4dddcf10ede33569e308a563ae64b58136a2cfcd1596e8e9b0e8c37b2a75b271', 'components/domain_reliability/bake_in_configs.py': '7f43fc331ade5e41caa7e973c40d3e819c017b0823898f281897817371f33a37', 'components/safe_browsing/content/browser/triggers/trigger_manager.cc': 'e736b8b3d41b18d1384f3ab1c18d236fe4499adfb16b3386c5f95be7412689b7', 'components/safe_browsing/core/common/safe_browsing_prefs.cc': 'da0ce67342d05c6b52516d21fb68365ee01266ce77e2a8bcaffe7ff945863610', 'components/safe_browsing/core/common/safe_browsing_prefs_unittest.cc': '68ad995ebe6260a3fcaabe929a1a3da61b3f3b41b145cd18cc3067aa6ef2554a', 'components/search_engines/android/template_url_service_android.cc': '7068b7e1fc6497350050cf4811be7c0af0bcbcf6053d163f35c80371ae348c9e', 'components/search_engines/template_url_service_unittest.cc': '5e99b2dfddfa2cdd2a80e05f5bb1fa78418001d0287921ef46b9061a79d357aa', 'components/sharing_message/features.cc': 'c2a797f0b5b5e54cdc4fe83628019efa31b58bcb5c3dfcff88efb8dda1f4f0e5', 'components/signin/core/browser/BUILD.gn': '7b24d91088b757302d0a9ee751c95861f0d5b9bba819ba335e36392266f81d47', 'components/signin/internal/identity_manager/gaia_cookie_manager_service.cc': '64b9ecc2770171e74f7051cd5bedaa17a706c91763e1a0b876768e5846a09d23', 'components/signin/internal/identity_manager/gaia_cookie_manager_service_unittest.cc': '7e8c41376fd9fef1a518518eacba562948c8b48bcfc86cc71ea451d034363a51', 'content/browser/file_system_access/file_system_access_safe_move_helper.h': '93e162341151221707a49a77ba6f8f221747ff61c69931ebfa178d1cdf459c29', 'storage/browser/quota/quota_features.cc': '73051a48c162bded135987473ccb1e7ed19d3f6b6d4bec88138a3b4dd4223973', 'storage/browser/quota/quota_manager_impl.cc': '15d2f700eca00f9741f1df6e2cba45ca46a1b4346308d9637b8c562e09791029', 'storage/browser/quota/quota_manager_unittest.cc': '8da1fc98fbd71a0f70833ecfee0686b3bc376e72980488988115f9d72b6c8005'}
PORT_PATCH_SHA256 = "26a2856cd6cb3acb97283898ef415be3c0afc0d2239028ffaebda0525dd17e43"
PENDING_BUILD_STATUS = "pending-unit-test-source-build"
FOCUSED_BUILD_TARGET = "chrome + focused modified test objects"
FOCUSED_TEST_OBJECTS = (
    "obj/chrome/browser/permissions/unit_tests/passage_embedder_delegate_unittest.o",
    "obj/components/signin/core/browser/unit_tests/account_preview_data_service_impl_unittest.o",
    "obj/chrome/browser/media/router/unittests/dns_sd_registry_unittest.o",
    "obj/chrome/browser/sync/test/integration/sync_integration_test_support/search_engines_helper.o",
    "obj/chrome/browser/autocomplete/unit_tests/search_provider_unittest.o",
    "obj/chrome/browser/browsing_data/unit_tests/chrome_browsing_data_remover_delegate_unittest.o",
    "obj/chrome/browser/download/unit_tests/download_item_model_unittest.o",
    "obj/chrome/browser/extensions/unit_tests/extension_allowlist_unittest.o",
    "obj/chrome/browser/extensions/unit_tests/extension_service_unittest.o",
    "obj/chrome/browser/new_tab_page/unit_tests/one_google_bar_loader_impl_unittest.o",
    "obj/chrome/browser/search_engines/unit_tests/template_url_service_unittest.o",
    "obj/chrome/browser/search_engines/unit_tests/template_url_service_sync_unittest.o",
    "obj/chrome/browser/search_engines/platform_browser_tests/prepopulated_engines_migration_browsertest.o",
    "obj/chrome/renderer/unit_tests/read_anything_app_controller_unittest.o",
    "obj/chrome/renderer/unit_tests/read_anything_app_model_unittest.o",
    "obj/chrome/renderer/unit_tests/read_anything_node_utils_unittest.o",
    "obj/components/search_engines/unit_tests/template_url_service_unittest.o",
    "obj/components/signin/internal/identity_manager/unit_tests/gaia_cookie_manager_service_unittest.o",
    "obj/storage/browser/unittests/quota_manager_unittest.o",
    "obj/chrome/browser/enterprise/reporting/test/test_support/test_utils.o",
)
ARGS_RELATIVE_PATH = "out/neantik157-port-smoke-correctargs3/args.gn"
ARGS_SHA256 = "8c013d5d2cbc3372f13e38d2220c6a698d13dd8dd7a0ed853197f21af253d46e"
HEX = re.compile(r"^[0-9a-f]{64}$")


class M157EvidenceError(ValueError):
    pass


def validate_focused_build_evidence(evidence: dict[str, Any]) -> None:
    aggregate = evidence.get("aggregateUnitTests")
    if (evidence.get("ninjaTarget") != FOCUSED_BUILD_TARGET or
            evidence.get("ninjaExitCode") != 0 or
            evidence.get("focusedTestObjects") != list(FOCUSED_TEST_OBJECTS) or
            evidence.get("focusedTestExitCode") != 0 or
            not isinstance(evidence.get("focusedTestLogSHA256"), str) or
            not HEX.fullmatch(evidence.get("focusedTestLogSHA256", "")) or
            not isinstance(aggregate, dict) or aggregate.get("status") != "blocked" or
            aggregate.get("exitCode") != 1 or
            not isinstance(aggregate.get("logSHA256"), str) or
            not HEX.fullmatch(aggregate.get("logSHA256", "")) or
            not isinstance(aggregate.get("failureBoundary"), list) or
            not aggregate.get("failureBoundary")):
        raise M157EvidenceError("Chromium 157 focused build evidence is incomplete or overstated")


def _sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _load(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise M157EvidenceError(f"Missing or unsafe {label}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise M157EvidenceError(f"Invalid JSON in {label}") from error
    if not isinstance(value, dict):
        raise M157EvidenceError(f"{label} must be an object")
    return value


def _git(repository: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise M157EvidenceError(f"Git source check failed: {result.stderr.strip()}")
    return result.stdout.strip()


def verify_contract(project_root: Path) -> dict[str, Any]:
    root = project_root.resolve()
    runtime = root / "runtime"
    contract_path, plan_path, adoption_path = (
        runtime / CONTRACT,
        runtime / PLAN,
        runtime / ADOPTION,
    )
    contract = _load(contract_path, "Chromium 157 source contract")
    plan = _load(plan_path, "Chromium 157 rebase plan")
    adoption = _load(adoption_path, "Chromium 157 source adoption manifest")
    upstream = {
        "repository": REPOSITORY,
        "tag": VERSION,
        "commit": OFFICIAL_COMMIT,
        "tree": OFFICIAL_TREE,
    }
    source = {
        "head": PORT_HEAD,
        "parent": PORT_PARENT,
        "sourceFileSHA256": PORT_SOURCE_FILE_SHA256,
        "sourcePatchManifestSHA256": PORT_PATCH_SHA256,
        "buildArgsPath": ARGS_RELATIVE_PATH,
        "buildArgsSHA256": ARGS_SHA256,
        "buildOutputDirectory": "out/neantik157-port-smoke-correctargs3",
        "changedFiles": list(PORT_SOURCE_FILE_SHA256),
    }
    dependency_sync = {
        "gitCheckouts": 151,
        "nonGitInputs": 50,
        "status": "verified by CURRENT-linked Chromium 157 sync receipt",
    }
    for document, name in ((contract, "contract"), (plan, "plan"), (adoption, "adoption")):
        if document.get("schemaVersion") != 1 or document.get("releaseReady") is not False:
            raise M157EvidenceError(f"Chromium 157 {name} must remain schema 1 and releaseReady=false")
        if document.get("targetChromiumVersion", document.get("chromiumVersion")) != VERSION:
            raise M157EvidenceError(f"Chromium 157 {name} version mismatch")
        if document.get("targetArchitecture") != "arm64":
            raise M157EvidenceError(f"Chromium 157 {name} must target arm64")
    if contract.get("sourceMode") != "official-chromium-stable-with-reviewed-neantik-port":
        raise M157EvidenceError("Chromium 157 source mode is not the reviewed stable port")
    if contract.get("officialChromiumBase") != upstream or plan.get("officialChromiumBase") != upstream:
        raise M157EvidenceError("Chromium 157 official source pin mismatch")
    if adoption.get("officialChromiumBase") != upstream:
        raise M157EvidenceError("Chromium 157 adoption manifest upstream pin mismatch")
    for document in (contract, plan, adoption):
        if document.get("portSource") != source:
            raise M157EvidenceError("Chromium 157 source head, file manifest or GN args pin mismatch")
        if document.get("dependencySync") != dependency_sync:
            raise M157EvidenceError("Chromium 157 dependency sync counts or evidence status mismatch")
    if plan.get("build") != {
            "outputDirectory": source["buildOutputDirectory"],
            "argsPath": source["buildArgsPath"],
            "argsSHA256": ARGS_SHA256,
            "target": FOCUSED_BUILD_TARGET,
            "status": "pending" if contract.get("binaryBindingStatus") == "pending-build" else "verified"}:
        raise M157EvidenceError("Chromium 157 rebase-plan build identity/state mismatch")
    if (adoption.get("buildOutputDirectory") != source["buildOutputDirectory"] or
            adoption.get("buildArgsPath") != source["buildArgsPath"] or
            adoption.get("buildArgsSHA256") != ARGS_SHA256 or
            adoption.get("buildEvidenceFile") != "runtime/" + BUILD_EVIDENCE):
        raise M157EvidenceError("Chromium 157 adoption manifest build identity mismatch")
    if contract.get("sourceAdoptionManifest") != "runtime/" + ADOPTION:
        raise M157EvidenceError("Chromium 157 adoption manifest path mismatch")
    if contract.get("rebasePlan") != "runtime/" + PLAN:
        raise M157EvidenceError("Chromium 157 rebase plan path mismatch")
    if contract.get("sourceAdoptionManifestSHA256") != _sha(adoption_path):
        raise M157EvidenceError("Chromium 157 adoption manifest digest mismatch")
    if contract.get("rebasePlanSHA256") != _sha(plan_path):
        raise M157EvidenceError("Chromium 157 rebase plan digest mismatch")
    license_path = runtime / "licenses" / "Chromium-LICENSE"
    if contract.get("chromiumLicenseSHA256") != _sha(license_path):
        raise M157EvidenceError("Chromium 157 license digest mismatch")
    baseline_path = runtime / "security-baseline.json"
    if contract.get("securityBaselineSHA256") != _sha(baseline_path):
        raise M157EvidenceError("Chromium 157 security baseline digest is stale")
    if contract.get("buildEvidenceFile") != "runtime/" + BUILD_EVIDENCE:
        raise M157EvidenceError("Chromium 157 build evidence path mismatch")
    if contract.get("binaryBindingStatus") == "pending-build":
        if (contract.get("status") != "source-pins-verified-build-pending" or
                contract.get("buildEvidenceStatus") != PENDING_BUILD_STATUS or
                contract.get("buildEvidenceSHA256") is not None or
                adoption.get("buildEvidenceSHA256") is not None or
                plan.get("buildEvidence", {}).get("status") != PENDING_BUILD_STATUS):
            raise M157EvidenceError("Chromium 157 pending-build state is inconsistent")
    elif contract.get("binaryBindingStatus") == "pending-runtime-report":
        evidence_path = runtime / BUILD_EVIDENCE
        evidence = _load(evidence_path, "Chromium 157 completed build evidence")
        if (contract.get("status") != "build-complete-runtime-report-pending" or
                contract.get("buildEvidenceStatus") != "completed-build-verified-runtime-report-pending" or
                contract.get("buildEvidenceSHA256") != _sha(evidence_path) or
                adoption.get("buildEvidenceSHA256") != _sha(evidence_path) or
                plan.get("buildEvidence", {}).get("status") != "verified" or
                plan.get("buildEvidence", {}).get("sha256") != _sha(evidence_path) or
                evidence.get("status") != "chromium-source-build-succeeded-unqualified" or
                evidence.get("chromiumVersion") != VERSION or
                evidence.get("officialCommit") != OFFICIAL_COMMIT or
                evidence.get("officialTree") != OFFICIAL_TREE or
                evidence.get("portHead") != PORT_HEAD or
                evidence.get("sourcePatchSHA256") != PORT_PATCH_SHA256 or
                evidence.get("buildConfigurationSHA256") != ARGS_SHA256 or
                evidence.get("buildOutputDirectory") != source["buildOutputDirectory"] or
                evidence.get("ninjaTarget") != FOCUSED_BUILD_TARGET or
                evidence.get("ninjaExitCode") != 0 or
                not isinstance(evidence.get("ninjaActionsCompleted"), int) or
                evidence.get("ninjaActionsCompleted") <= 0 or
                evidence.get("ninjaActionsCompleted") != evidence.get("ninjaActionsExpected") or
                not isinstance(evidence.get("buildLogSHA256"), str) or
                not HEX.fullmatch(evidence.get("buildLogSHA256", "")) or
                evidence.get("focusedTestObjects") != list(FOCUSED_TEST_OBJECTS) or
                evidence.get("focusedTestExitCode") != 0 or
                not isinstance(evidence.get("focusedTestLogSHA256"), str) or
                not HEX.fullmatch(evidence.get("focusedTestLogSHA256", "")) or
                evidence.get("aggregateUnitTests", {}).get("status") != "blocked" or
                evidence.get("aggregateUnitTests", {}).get("exitCode") != 1 or
                not isinstance(evidence.get("aggregateUnitTests", {}).get("logSHA256"), str) or
                not HEX.fullmatch(evidence.get("aggregateUnitTests", {}).get("logSHA256", "")) or
                not evidence.get("aggregateUnitTests", {}).get("failureBoundary") or
                not isinstance(evidence.get("browserExecutableSHA256"), str) or
                not HEX.fullmatch(evidence.get("browserExecutableSHA256", "")) or
                not isinstance(evidence.get("frameworkSHA256"), str) or
                not HEX.fullmatch(evidence.get("frameworkSHA256", "")) or
                not isinstance(evidence.get("browserExecutableRelativePath"), str) or
                not evidence.get("browserExecutableRelativePath") or
                not isinstance(evidence.get("frameworkRelativePath"), str) or
                not evidence.get("frameworkRelativePath") or
                evidence.get("releaseReady") is not False):
            raise M157EvidenceError("Chromium 157 completed build evidence is inconsistent")
        validate_focused_build_evidence(evidence)
    else:
        raise M157EvidenceError("Chromium 157 contract has unknown binary-binding state")
    return contract


def verify_source_root(source_root: Path, project_root: Path) -> dict[str, Any]:
    contract = verify_contract(project_root)
    if source_root.is_symlink() or not source_root.is_absolute() or not source_root.is_dir():
        raise M157EvidenceError("Chromium 157 source root must be absolute and non-symlinked")
    source_root = source_root.resolve()
    if _git(source_root, "rev-parse", "HEAD") != PORT_HEAD:
        raise M157EvidenceError("Chromium 157 port source HEAD mismatch")
    if _git(source_root, "rev-parse", "HEAD^") != PORT_PARENT:
        raise M157EvidenceError("Chromium 157 port source parent mismatch")
    if _git(source_root, "rev-parse", OFFICIAL_COMMIT + "^{tree}") != OFFICIAL_TREE:
        raise M157EvidenceError("Chromium 157 official commit tree mismatch")
    if _git(source_root, "merge-base", "--is-ancestor", OFFICIAL_COMMIT, "HEAD") == "":
        # `merge-base --is-ancestor` has no stdout on success; the helper raises
        # on non-zero, so this explicit form documents the required relation.
        pass
    version_file = source_root / "chrome" / "VERSION"
    if version_file.is_symlink() or not version_file.is_file():
        raise M157EvidenceError("Chromium 157 version file is missing or unsafe")
    version = {}
    for line in version_file.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            version[key] = value
    if ".".join(version.get(key, "") for key in ("MAJOR", "MINOR", "BUILD", "PATCH")) != VERSION:
        raise M157EvidenceError("Chromium 157 version file mismatch")
    changed_files = _git(source_root, "diff", "HEAD", "--name-only").splitlines()
    if changed_files != list(PORT_SOURCE_FILE_SHA256):
        raise M157EvidenceError("Chromium 157 changed source file list mismatch")
    for relative, expected_sha256 in PORT_SOURCE_FILE_SHA256.items():
        path = source_root / relative
        if path.is_symlink() or not path.is_file() or _sha(path) != expected_sha256:
            raise M157EvidenceError(f"Chromium 157 source file digest mismatch: {relative}")
    patch_manifest = {"head": PORT_HEAD, "parent": PORT_PARENT,
                      "files": PORT_SOURCE_FILE_SHA256}
    if _sha_bytes(json.dumps(patch_manifest, sort_keys=True, separators=(",", ":")).encode()) != PORT_PATCH_SHA256:
        raise M157EvidenceError("Chromium 157 source patch manifest digest mismatch")
    args_path = source_root / ARGS_RELATIVE_PATH
    if args_path.is_symlink() or not args_path.is_file() or _sha(args_path) != ARGS_SHA256:
        raise M157EvidenceError("Chromium 157 GN args path or digest mismatch")
    deps = source_root / "DEPS"
    if deps.is_symlink() or not deps.is_file():
        raise M157EvidenceError("Chromium 157 DEPS file is missing or unsafe")
    deps_text = deps.read_text(encoding="utf-8")
    required_pins = {
        "skia_revision": "ca84ce0a6f1659748188469a89361ccea71e3a64",
        "v8_revision": "440c1c463e2e528c309af5067952e7b11631507f",
        "pdfium_revision": "a4d199fba716a1edcc5d032a1d875f9a8ef2c283",
        "ffmpeg_revision": "5c85ff666b3434d9323b83437f910ad8431ab7c9",
    }
    for name, revision in required_pins.items():
        if not re.search(r"['\"]" + re.escape(name) + r"['\"]\s*:\s*['\"]" + revision + r"['\"]", deps_text):
            raise M157EvidenceError(f"Chromium 157 dependency pin mismatch: {name}")
    result = {"sourceHead": PORT_HEAD, "officialCommit": OFFICIAL_COMMIT,
              "officialTree": OFFICIAL_TREE, "sourcePatchSHA256": PORT_PATCH_SHA256,
              "buildArgsSHA256": ARGS_SHA256,
              "buildOutputDirectory": contract["portSource"]["buildOutputDirectory"]}
    return result


def build_provenance(source_root: Path, project_root: Path) -> dict[str, Any]:
    source = verify_source_root(source_root, project_root)
    contract = verify_contract(project_root)
    if contract.get("binaryBindingStatus") != "pending-runtime-report":
        raise M157EvidenceError("Chromium 157 source pins are verified but the exact Ninja build is still pending")
    evidence_path = project_root.resolve() / "runtime" / BUILD_EVIDENCE
    evidence = _load(evidence_path, "Chromium 157 build evidence")
    return _expected_provenance(contract, evidence, source, project_root)


def _expected_provenance(contract: dict[str, Any], evidence: dict[str, Any],
                         source: dict[str, Any], project_root: Path) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "status": "source-qualified",
        "sourceMode": contract["sourceMode"],
        "targetChromiumVersion": VERSION,
        "targetArchitecture": "arm64",
        "officialChromiumBase": contract["officialChromiumBase"],
        "sourceContractSHA256": _sha(project_root.resolve() / "runtime" / CONTRACT),
        "sourceAdoptionManifestSHA256": _sha(project_root.resolve() / "runtime" / ADOPTION),
        "sourceHead": source["sourceHead"],
        "sourcePatchSHA256": source["sourcePatchSHA256"],
        "buildArgsSHA256": source["buildArgsSHA256"],
        "buildEvidenceSHA256": _sha(project_root.resolve() / "runtime" / BUILD_EVIDENCE),
        "buildEvidence": {"ninjaTarget": evidence["ninjaTarget"],
                          "ninjaExitCode": evidence["ninjaExitCode"],
                          "ninjaActionsCompleted": evidence["ninjaActionsCompleted"],
                          "ninjaActionsExpected": evidence["ninjaActionsExpected"],
                          "buildLogSHA256": evidence["buildLogSHA256"],
                          "focusedTestObjects": evidence["focusedTestObjects"],
                          "focusedTestLogSHA256": evidence["focusedTestLogSHA256"],
                          "aggregateUnitTests": evidence["aggregateUnitTests"],
                          "browserExecutableSHA256": evidence["browserExecutableSHA256"],
                          "frameworkSHA256": evidence["frameworkSHA256"]},
        "sourceChecks": {"officialCommitTree": "verified", "versionFile": "verified",
                          "pinnedDependencies": "verified", "reviewedPortDiff": "verified",
                          "buildArgs": "verified", "buildEvidence": "verified"},
        "binaryBinding": {"status": "pending-runtime-report",
                          "requiredEvidence": "schema-3-runtime-report"},
        "releaseReady": False,
    }


def verify_provenance(document: dict[str, Any], project_root: Path) -> None:
    contract = verify_contract(project_root)
    if contract.get("binaryBindingStatus") != "pending-runtime-report":
        raise M157EvidenceError("Chromium 157 provenance cannot be accepted before exact build evidence")
    runtime = project_root.resolve() / "runtime"
    evidence = _load(runtime / BUILD_EVIDENCE, "Chromium 157 build evidence")
    source = {"sourceHead": PORT_HEAD, "sourcePatchSHA256": PORT_PATCH_SHA256,
              "buildArgsSHA256": ARGS_SHA256,
              "buildOutputDirectory": contract["portSource"]["buildOutputDirectory"]}
    expected = _expected_provenance(contract, evidence, source, project_root)
    if document != expected:
        raise M157EvidenceError("Chromium 157 source provenance differs from pinned evidence")


def expected_lock(provenance_path: Path, project_root: Path) -> dict[str, Any]:
    provenance = _load(provenance_path, "Chromium 157 provenance")
    verify_provenance(provenance, project_root)
    contract = verify_contract(project_root)
    base = contract["officialChromiumBase"]
    return {
        "schemaVersion": 4,
        "status": "source-qualified",
        "targetArchitecture": "arm64",
        "sourceContractSHA256": _sha(project_root.resolve() / "runtime" / CONTRACT),
        "sourceProvenanceSHA256": _sha(provenance_path),
        "sourceAdoptionManifestSHA256": _sha(project_root.resolve() / "runtime" / ADOPTION),
        "fingerprintChromium": {"repository": base["repository"], "tag": base["tag"],
                                "commit": base["commit"], "tree": base["tree"],
                                "chromiumVersion": VERSION,
                                "licenseSHA256": contract["chromiumLicenseSHA256"]},
        "ownedInputs": {"sourcePatchSHA256": PORT_PATCH_SHA256,
                         "buildArgsSHA256": ARGS_SHA256},
        "ownedManifests": {
            "neantikPatchSeriesSHA256": _sha(project_root.resolve() / "runtime/nevision-patches/series.json"),
            "appleDeviceTuplesSHA256": _sha(project_root.resolve() / "runtime/apple-device-tuples.json"),
            "securityBaselineSHA256": _sha(project_root.resolve() / "runtime/security-baseline.json"),
        },
        "binaryBinding": {"status": "not-attested-by-this-document",
                          "requiredEvidence": "schema-3-runtime-report",
                          "policy": "This source-only lock makes no runtime, signing, notarization, publication or release claim."},
    }


def verify_lock(lock: dict[str, Any], provenance_path: Path, project_root: Path) -> dict[str, Any]:
    if lock != expected_lock(provenance_path, project_root):
        raise M157EvidenceError("Chromium 157 candidate lock is stale or mutated")
    return lock
