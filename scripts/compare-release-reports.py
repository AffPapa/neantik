#!/usr/bin/env python3
"""Compare declared public release evidence; never run or qualify a browser."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
GATES = (
    ("notarization", "Нотарификация"), ("stapling", "Stapling"),
    ("Gatekeeper", "Gatekeeper"), ("DirectDoctor", "Direct doctor"),
    ("nativeUpdater", "Установка обновления"), ("nativeRollback", "Откат"),
    ("GUIFingerprint", "Запуск локальной подписанной сборки"),
    ("downloadedHeaded", "Запуск скачанной копии"),
    ("MCPExactSigned", "MCP подписанного кандидата"),
    ("downloadedMCP", "MCP скачанной копии"),
    ("hostedZIP", "Публичный ZIP"), ("hostedDMG", "Публичный DMG"),
    ("site", "Сайт"),
)
CONTEXT_KEYS = ("osVersion", "architecture", "headed", "memoryPressure", "thermalState",
                "environmentSHA256", "harnessSHA256", "fixtureSHA256", "profileConfigurationSHA256")


class ReportError(ValueError):
    pass


def identity(record):
    if not isinstance(record, dict):
        raise ReportError("Release record must be an object")
    version = record.get("version")
    build = record.get("build")
    runtime = record.get("runtime")
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ReportError("Invalid release version")
    if type(build) is not int or build <= 0 or not isinstance(runtime, dict):
        raise ReportError("Invalid release identity")
    result = {"version": version, "build": build,
              "sourceCommit": record.get("sourceCommit"),
              "managerBuildSourceCommit": record.get("managerBuildSourceCommit", record.get("sourceCommit")),
              "managerSHA256": record.get("managerSHA256")}
    if not isinstance(result["sourceCommit"], str) or not SHA1.fullmatch(result["sourceCommit"]):
        raise ReportError("Missing source commit")
    if not isinstance(result["managerBuildSourceCommit"], str) or not SHA1.fullmatch(result["managerBuildSourceCommit"]):
        raise ReportError("Missing manager build source commit")
    if not isinstance(result["managerSHA256"], str) or not SHA256.fullmatch(result["managerSHA256"]):
        raise ReportError("Missing manager digest")
    result["runtime"] = {}
    for key in ("chromiumVersion", "architecture", "executableSHA256", "frameworkSHA256"):
        value = runtime.get(key)
        if not isinstance(value, str):
            raise ReportError("Missing runtime identity")
        if key.endswith("SHA256") and not SHA256.fullmatch(value):
            raise ReportError("Invalid runtime digest")
        if key == "chromiumVersion" and not re.fullmatch(r"\d+(?:\.\d+){3}", value):
            raise ReportError("Invalid Chromium version")
        if key == "architecture" and value not in ("arm64", "x86_64"):
            raise ReportError("Unsupported architecture")
        result["runtime"][key] = value
    return result


def public_texts(record, key):
    values = record.get(key, [])
    if not isinstance(values, list) or len(values) > 100:
        raise ReportError("Invalid public release text list")
    if any(not isinstance(x, str) or len(x) > 2000 for x in values):
        raise ReportError("Invalid public release text")
    return values


def declared_gate(value):
    """Normalize only clear declarations, never search any occurrence of PASS."""
    if value is None:
        return {"state": "unknown"}
    if isinstance(value, dict):
        if type(value.get("passed")) is bool:
            return {"state": "reported_pass" if value["passed"] else "reported_fail"}
        if value.get("ZIP") == "Accepted" and value.get("DMG") == "Accepted":
            return {"state": "reported_pass"}
        return {"state": "unknown"}
    if not isinstance(value, str) or len(value) > 2000:
        raise ReportError("Invalid verification declaration")
    lower = value.casefold()
    if any(x in lower for x in ("open:", "not deployed", "unverified", "unavailable", "not allgreen", "not all green", "not qualified", "not tested")) or re.search(r"\b(?:no|not|without|false|unconfirmed)\s*pass\b", lower):
        state = "open"
    elif lower.startswith(("fail", "error")):
        state = "reported_fail"
    elif value == "PASS" or value.startswith("PASS ") or value == "13/13PASS":
        state = "reported_pass"
    elif value.endswith("PASS") and not any(x in lower for x in ("fail", "error", "partial", "skip")):
        state = "reported_pass"
    elif value.endswith("MATCH") and not any(x in lower for x in ("fail", "error", "mismatch", "partial")):
        state = "reported_match"
    else:
        state = "declaration_only"
    return {"state": state, "declaration": value}


def comparison_context(record):
    context = record.get("measurementContext")
    if not isinstance(context, dict) or any(key not in context for key in CONTEXT_KEYS):
        return None
    if type(context["headed"]) is not bool or context["architecture"] != record["runtime"]["architecture"]:
        return None
    if type(context["memoryPressure"]) is not int or context["memoryPressure"] not in (1, 2, 4):
        return None
    if type(context["thermalState"]) is not int or context["thermalState"] not in (0, 1, 2, 3):
        return None
    if not isinstance(context["osVersion"], str) or not re.fullmatch(r"\d+(?:\.\d+){1,3}", context["osVersion"]):
        return None
    for key in CONTEXT_KEYS:
        if key.endswith("SHA256") and (not isinstance(context[key], str) or not SHA256.fullmatch(context[key])):
            return None
    # Unknown fields, including raw fingerprint/user data, are never copied.
    return {key: context[key] for key in CONTEXT_KEYS}


def test_declarations(verification):
    """Keep published summaries and their skips/errors; exclude unknown fields."""
    source = verification.get("tests", {})
    if not isinstance(source, dict):
        raise ReportError("Invalid test declarations")
    result = {}
    for key in ("Swift", "Python", "Harness", "site"):
        if key not in source:
            continue
        value = source[key]
        if not isinstance(value, str) or len(value) > 2000:
            raise ReportError("Invalid published test summary")
        result[key] = value
    return result


def compare(before, after):
    old, new = identity(before), identity(after)
    if tuple(map(int, new["version"].split("."))) <= tuple(map(int, old["version"].split("."))) or new["build"] <= old["build"]:
        raise ReportError("Comparison requires a newer unique version and build")
    a, b = comparison_context(before), comparison_context(after)
    missing = a is None or b is None
    differences = [] if missing else [key for key in CONTEXT_KEYS if a[key] != b[key]]
    contexts_match = not missing and not differences
    gates = []
    old_gates, new_gates = before.get("verification", {}), after.get("verification", {})
    if not isinstance(old_gates, dict) or not isinstance(new_gates, dict):
        raise ReportError("Invalid verification object")
    for key, label in GATES:
        old_value = old_gates.get("liveSite") if key == "site" and "site" not in old_gates else old_gates.get(key)
        new_value = new_gates.get("liveSite") if key == "site" and "site" not in new_gates else new_gates.get(key)
        first, second = declared_gate(old_value), declared_gate(new_value)
        gates.append({"key": key, "label": label, "before": first, "after": second,
                      "reportedStateChanged": first["state"] != second["state"]})
    return {
        "schemaVersion": 1,
        "scope": "Declared public release records, not an independent runtime audit",
        "before": old, "after": new,
        "identityComparison": {
            "managerExecutableChanged": old["managerSHA256"] != new["managerSHA256"],
            "runtimeExecutableDigestsEqual": all(old["runtime"][key] == new["runtime"][key]
                for key in ("executableSHA256", "frameworkSHA256")),
            "fullRuntimeInventoryCompared": False,
        },
        "measurementComparability": {
            "declaredContextsMatch": contexts_match,
            "reason": "missing_context" if missing else "different_context" if differences else "matching_declared_context",
            "differingFields": differences,
            "before": a, "after": b,
            "independentlyVerified": False,
        },
        "behaviorRegressionVerdict": "not_established",
        "performanceComparison": "not_measured",
        "verification": gates,
        "testDeclarations": {"before": test_declarations(old_gates), "after": test_declarations(new_gates)},
        "qualificationDeclaration": {"before": old_gates.get("releaseQualified") if type(old_gates.get("releaseQualified")) is bool else None,
                                     "after": new_gates.get("releaseQualified") if type(new_gates.get("releaseQualified")) is bool else None},
        "reportedChanges": public_texts(after, "changes"),
        "reportedLimitations": public_texts(after, "limitations"),
        "noBrowserLaunched": True,
    }


def markdown(report):
    a, b = report["before"], report["after"]
    lines = [f'# Сравнение NeAntik {a["version"]} ({a["build"]}) → {b["version"]} ({b["build"]})', "",
             "Сводка опубликованных отчётов. Она не запускает браузер и не заменяет проверку релиза.", "",
             "## Что изменилось", ""]
    lines += ["- " + item for item in report.get("localizedChanges", report["reportedChanges"])]
    equal = report["identityComparison"]["runtimeExecutableDigestsEqual"]
    context_text = {"missing_context": "В исходных записях не хватает сведений об условиях измерения.",
                    "different_context": "Условия измерения различаются.",
                    "matching_declared_context": "Заявленные условия совпадают; подлинность измерений здесь не проверяется."}
    lines += ["", "## Runtime и условия сравнения", "",
              "SHA-256 основного исполняемого файла Chromium и исполняемого файла Framework " + ("совпадают." if equal else "различаются."),
              "Полный инвентарь runtime здесь не сравнивается. Совпадение хешей не доказывает одинаковое поведение.",
              context_text[report["measurementComparability"]["reason"]],
              "Вывод об отсутствии поведенческих регрессий не установлен. Производительность не измерялась.", "",
              "## Состояние проверок в исходных отчётах", "",
              "| Проверка | До | После |", "| --- | --- | --- |"]
    labels = {"reported_pass": "заявлен PASS", "reported_fail": "заявлен отказ", "open": "открыта",
              "reported_match": "заявлено совпадение", "unknown": "нет однозначного результата",
              "declaration_only": "есть описание, без вывода PASS"}
    lines += [f'| {x["label"]} | {labels[x["before"]["state"]]} | {labels[x["after"]["state"]]} |' for x in report["verification"]]
    lines += ["", "## Тесты, указанные в отчётах", "",
              "Число reported-тестов включает явно пропущенные проверки. Эти записи не являются новым прогоном.", "",
              "| Набор | До | После |", "| --- | --- | --- |"]
    for key in ("Swift", "Python", "Harness", "site"):
        def cell(side):
            return report["testDeclarations"][side].get(key, "не указан").replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {key} | {cell('before')} | {cell('after')} |")
    lines += ["", "## Ограничения", ""] + ["- " + item for item in report.get("localizedLimitations", report["reportedLimitations"])]
    lines += ["", "Исходные записи: " + ", ".join(f'[v{x["version"]}.json](../../releases/v{x["version"]}.json)' for x in (a, b)), ""]
    return "\n".join(lines)


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ReportError("Duplicate JSON key")
        result[key] = value
    return result


def load_version(version):
    if not VERSION.fullmatch(version):
        raise ReportError("Use a canonical numeric release version")
    directory = ROOT / "releases"
    if directory.is_symlink():
        raise ReportError("Release directory unsafe")
    path = directory / ("v" + version + ".json")
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 512 * 1024:
        raise ReportError("Release record unavailable or unsafe")
    data = path.read_bytes()
    record = json.loads(data, object_pairs_hook=reject_duplicates,
                        parse_constant=lambda _: (_ for _ in ()).throw(ReportError("Invalid JSON number")))
    if identity(record)["version"] != version:
        raise ReportError("Release filename and version differ")
    return record, hashlib.sha256(data).hexdigest()


def localized_notes(version, build):
    path = ROOT / "releases" / ("v" + version + ".md")
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 512 * 1024:
        raise ReportError("Public release notes unavailable or unsafe")
    data = path.read_bytes()
    text = data.decode("utf-8")
    lines = text.splitlines()
    if not lines or lines[0] != f"# NeAntik {version} ({build})":
        raise ReportError("Release notes identity differs")
    changes, limitations = [], []
    section = None
    for line in lines[1:]:
        if line == "## Что изменилось":
            section = "changes"
        elif line == "## Ограничения":
            section = "limitations"
        elif line.startswith("## "):
            section = None
        elif section == "changes" and line.startswith("- "):
            changes.append(line[2:])
        elif section == "limitations" and line.strip():
            limitations.append(line[2:] if line.startswith("- ") else line)
    if not changes or not limitations:
        raise ReportError("Public changes section missing")
    return changes, limitations, hashlib.sha256(data).hexdigest()


def build_version_comparison(before_version, after_version):
    old, old_hash = load_version(before_version)
    new, new_hash = load_version(after_version)
    report = compare(old, new)
    report["localizedChanges"], report["localizedLimitations"], notes_hash = localized_notes(after_version, report["after"]["build"])
    report["sourceRecordSHA256"] = {"before": old_hash, "after": new_hash}
    report["sourceNotesSHA256"] = notes_hash
    return report


def require_matching_snapshot(expected, stored, rendered):
    """Reject stale records and invented conclusions, rather than upgrading them."""
    # Python equality treats True == 1 and 124 == 124.0. JSON types matter here.
    try:
        canonical_expected = json.dumps(expected, sort_keys=True, separators=(",", ":"), allow_nan=False)
        canonical_stored = json.dumps(stored, sort_keys=True, separators=(",", ":"), allow_nan=False)
    except (TypeError, ValueError) as error:
        raise ReportError("Invalid comparison snapshot") from error
    if canonical_stored != canonical_expected or rendered != markdown(expected):
        raise ReportError("Comparison snapshot differs from public sources")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--verify-snapshot", action="store_true",
                        help="Check retained JSON/Markdown against current public records; no runtime qualification")
    args = parser.parse_args()
    try:
        report = build_version_comparison(args.before, args.after)
        if args.verify_snapshot:
            stem = f"regression-{args.before}-{args.after}"
            paths = [ROOT / "docs/evidence" / (stem + suffix) for suffix in (".json", ".md")]
            if any(p.is_symlink() or not p.is_file() or p.stat().st_size > 512 * 1024 for p in paths):
                raise ReportError("Comparison snapshot unavailable or unsafe")
            stored = json.loads(paths[0].read_text(), object_pairs_hook=reject_duplicates)
            require_matching_snapshot(report, stored, paths[1].read_text())
    except (OSError, UnicodeError, json.JSONDecodeError, ReportError):
        parser.error("Release comparison inputs unavailable or invalid; no qualification performed")
    if args.verify_snapshot:
        print("PASS: comparison snapshots match public source records; no runtime qualification performed")
    elif args.format == "markdown":
        print(markdown(report), end="")
    else:
        print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
