#!/usr/bin/env python3
"""Self-check for hypervisor-backups.py.  Run: python3 scripts/test_hypervisor_backups.py

Covers the decisions that fail silently: whether a host's weekly backup is fresh, whether a
snapshot exists (Hostinger answers id 0, not 404, when there is none), and the action poll,
which must end on `success` -- never on the first answer that merely is not an error.
No request is made; the half that talks to Hostinger was proved by running it against both
hosts (docs/backup-restore.md, "Hypervisor backups").
"""
import datetime as dt
import importlib.util
import pathlib

HERE = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("hypervisor_backups", HERE / "hypervisor-backups.py")
hb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hb)

NOW = dt.datetime(2026, 9, 14, 14, 0, tzinfo=dt.timezone.utc)
WEEKLY = [
    {"id": 51293138, "created_at": "2026-09-08T05:23:53Z"},
    {"id": 50412502, "created_at": "2026-09-01T06:28:11Z"},
]

# Fresh: the newest weekly backup is inside the limit, whatever order the API lists them in.
ok, msg = hb.backup_verdict(list(reversed(WEEKLY)), NOW, max_age_days=8)
assert ok, msg
assert "2026-09-08" in msg, msg

# Stale: past the limit fails and says how old.
ok, msg = hb.backup_verdict(WEEKLY, NOW + dt.timedelta(days=3), max_age_days=8)
assert not ok and "9 days" in msg, msg

# None at all fails -- an empty list is not "nothing to worry about".
ok, msg = hb.backup_verdict([], NOW, max_age_days=8)
assert not ok and "no backups" in msg, msg

# A snapshot with id 0 is Hostinger's "there is none"; its created_at is just the request time.
assert not hb.snapshot_exists({"id": 0, "created_at": "2026-09-14T14:04:15Z"})
assert hb.snapshot_exists({"id": 912, "created_at": "2026-09-14T14:04:15Z"})


def poll_with(states):
    seen = iter(states)
    clock = {"t": 0.0}

    def fetch():
        return {"id": 1, "state": next(seen)}

    def sleep(s):
        clock["t"] += s

    return lambda timeout=600: hb.poll_action(fetch, sleep, lambda: clock["t"], interval=10, timeout=timeout)


# The poll waits through created/sent/delayed -- and CLAUDE.md's `started` -- until success.
assert poll_with(["created", "sent", "started", "delayed", "success"])()["state"] == "success"

# error ends it, raised.
try:
    poll_with(["sent", "error"])()
except hb.ActionFailed as e:
    assert "error" in str(e)
else:
    raise AssertionError("an action in state error must raise")

# Running out of time raises rather than returning the last non-final state.
try:
    poll_with(["sent"] * 100)(timeout=60)
except hb.ActionFailed as e:
    assert "sent" in str(e) and "60" in str(e)
else:
    raise AssertionError("a poll past its timeout must raise")

# Hosts are matched by hostname prefix to the repo's names, and an unknown one is refused.
VMS = [{"id": 1778283, "hostname": "bpvps1.cloud"}, {"id": 1831058, "hostname": "bpvps2.cloud"}]
assert hb.vm_id(VMS, "bpvps2") == 1831058
try:
    hb.vm_id(VMS, "vps3-prod")
except KeyError:
    pass
else:
    raise AssertionError("a host this token cannot see must be refused")

print("hypervisor-backups: all checks passed")
