# Resource admission API

`kern.memorystatus_vm_pressure_level` returns **userspace notification flags**:

| Value | Meaning | New runtime attempt |
| --- | --- | --- |
| 1 | Normal | Allowed if thermal state is nominal or fair |
| 2 | Warning | Refused |
| 4 | Critical | Refused |
| Other or unavailable | Unknown | Refused |

Do not use the internal XNU enum (0 Normal, 1 Warning, and so on) for this
sysctl. The [sysctl handler](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c)
converts that enum to dispatch flags before returning the value. The exported
constants are in [event_private.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/event_private.h).

Use `scripts/native-qa-readiness.py --check` in the authorized host context.
Unknown observations fail closed. A resource observation permits an attempt;
it does not prove browser behavior or release readiness. The manager and the
standalone WebKit host sample the same kernel flag before new work and check
thermal state. If the live memory sample is unavailable, they retain the
last known pressure state and use Dispatch notifications for updates.

Older receipts that called raw value 1 Warning used an incorrect interpretation.
Preserve their original bytes, but do not reuse that label as a current blocker.
