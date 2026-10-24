#!/usr/bin/env python3
"""Observe macOS resource admission before native QA; never launch or certify it."""
import argparse
import ctypes
import datetime
import errno
import json
import subprocess
import sys


def observe_memory_pressure():
    # Free-memory percentage is not the kernel pressure state used for admission.
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
        capture_output=True, text=True, timeout=5, check=True,
    )
    return int(result.stdout.strip())


def observe_thermal_state():
    # Load Foundation explicitly; do not depend on classes loaded by another app.
    ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
    objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    send_object = ctypes.CFUNCTYPE(
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p
    )(("objc_msgSend", objc))
    process_info = send_object(
        objc.objc_getClass(b"NSProcessInfo"), objc.sel_registerName(b"processInfo")
    )
    if not process_info:
        raise RuntimeError("Thermal observer unavailable")
    send_integer = ctypes.CFUNCTYPE(
        ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p
    )(("objc_msgSend", objc))
    return send_integer(process_info, objc.sel_registerName(b"thermalState"))


def assess(pressure, thermal):
    reasons = []
    if pressure not in (1, 2, 4):
        reasons.append("memory_pressure_unknown")
    elif pressure != 1:
        reasons.append("memory_pressure_warning" if pressure == 2 else "memory_pressure_critical")
    if thermal not in (0, 1, 2, 3):
        reasons.append("thermal_unknown")
    elif thermal >= 2:
        reasons.append("thermal_serious" if thermal == 2 else "thermal_critical")
    return {
        "schemaVersion": 1,
        "status": "not-run",
        "eligibleForAttempt": not reasons,
        "memoryPressure": pressure if pressure in (1, 2, 4) else None,
        "thermalState": thermal if thermal in (0, 1, 2, 3) else None,
        "reasons": reasons,
        "releaseQualified": False,
        "boundary": "Resource observation only; live manager admission and exact native gates remain required",
    }


def classify_observer_failure(error):
    """Return a safe diagnostic category without exposing command or OS text."""
    if isinstance(error, OSError) and error.errno in (errno.EPERM, errno.EACCES):
        return "permission_denied"
    if isinstance(error, subprocess.CalledProcessError):
        diagnostic = (error.stderr or "").lower()
        if "operation not permitted" in diagnostic or "permission denied" in diagnostic:
            return "permission_denied"
    if isinstance(error, subprocess.TimeoutExpired):
        return "timeout"
    if isinstance(error, FileNotFoundError):
        return "observer_unavailable"
    return "observer_failed"


def observe(platform=sys.platform, memory_reader=observe_memory_pressure,
            thermal_reader=observe_thermal_state):
    if platform != "darwin":
        report = assess(None, None)
        report["reasons"] = ["macos_required"]
    else:
        # A failed observer is unknown, not normal. Raw system errors are private.
        observer_failures = {}
        try:
            pressure = memory_reader()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            pressure = None
            observer_failures["memoryPressure"] = classify_observer_failure(error)
        try:
            thermal = thermal_reader()
        except (OSError, ValueError, RuntimeError) as error:
            thermal = None
            observer_failures["thermalState"] = classify_observer_failure(error)
        report = assess(pressure, thermal)
        if observer_failures:
            report["observerFailures"] = observer_failures
    report["observedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    return report


def exit_code(report):
    if report["eligibleForAttempt"]:
        return 0
    return 78 if any(reason.endswith("unknown") or reason == "macos_required"
                     for reason in report["reasons"]) else 75


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="Exit 75 when resources refuse an attempt, 78 when observation is unavailable")
    args = parser.parse_args()
    report = observe()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return exit_code(report) if args.check else 0


if __name__ == "__main__":
    raise SystemExit(main())
