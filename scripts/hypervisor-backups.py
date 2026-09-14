#!/usr/bin/env python3
"""hypervisor-backups.py -- the host-level recovery layer for bpvps1 and bpvps2.

    python scripts/hypervisor-backups.py status              # exit 1 if a weekly backup is stale
    python scripts/hypervisor-backups.py snapshot bpvps2     # take a snapshot, poll it to success
    python scripts/hypervisor-backups.py snapshot bpvps2 --replace   # ... over an existing one

Independent of restic: Hostinger's own copy of the whole VM, on Hostinger's storage, restored
from hPanel or the API. It is what is left if the host is lost with its restic passphrase.

Two things, and only two, exist in Hostinger's VPS API (checked 2026-09-14 against its OpenAPI):

  weekly backups   Automatic on both hosts. There is NO endpoint to enable, schedule or
                   disable them -- only to list and restore. `status` proves they are running.
  one snapshot     On demand, one per VM, and a new one OVERWRITES the old. Taken with
                   `snapshot` before a risky change to the host itself.

The token is HOSTINGER_API_TOKEN (Blueprint account), from the environment or .env. It sees
bpvps1 and bpvps2 and nothing else -- the Teeko hosts are in no account we hold a token for.

Hostinger's API sits behind Cloudflare and answers a bare urllib request `403 error code:
1010`, so every request sends a normal User-Agent. A sync-style action must be polled to
`success`: the resource's own flags flip before the work is done.
Runbook: docs/backup-restore.md, "Hypervisor backups".
"""
import argparse
import datetime as dt
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

API = "https://developers.hostinger.com/api/vps/v1"
HOSTS = ("bpvps1", "bpvps2")
# Weekly, plus a day of slack for Hostinger's schedule drifting (it has: 05:23, then 06:28 UTC).
MAX_AGE_DAYS = 8


class ActionFailed(Exception):
    pass


def parse_time(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def backup_verdict(backups, now, max_age_days=MAX_AGE_DAYS):
    """(ok, message) for one VM's backup list."""
    if not backups:
        return False, "no backups listed"
    newest = max(backups, key=lambda b: parse_time(b["created_at"]))
    age = now - parse_time(newest["created_at"])
    msg = f"newest weekly backup {newest['created_at']} ({age.days} days old, {len(backups)} kept)"
    return age <= dt.timedelta(days=max_age_days), msg


def snapshot_exists(snapshot):
    # With no snapshot the API still answers 200 -- id 0, created_at set to the request time.
    return bool(snapshot.get("id"))


def poll_action(fetch, sleep, clock, interval=10, timeout=1800):
    """Poll until the action is `success`; raise on `error` or on running out of time."""
    start = clock()
    while True:
        action = fetch()
        state = action.get("state")
        if state == "success":
            return action
        if state == "error":
            raise ActionFailed(f"action {action.get('id')} ended in state error")
        if clock() - start >= timeout:
            raise ActionFailed(f"action {action.get('id')} still '{state}' after {timeout}s")
        sleep(interval)


def vm_id(vms, host):
    for vm in vms:
        if vm.get("hostname", "").split(".")[0] == host:
            return vm["id"]
    raise KeyError(f"{host}: not a VM this token can see ({', '.join(v.get('hostname', '?') for v in vms)})")


# ── the half that talks to Hostinger ─────────────────────────────────────────────────

def token():
    value = os.environ.get("HOSTINGER_API_TOKEN")
    env = pathlib.Path(__file__).resolve().parent.parent / ".env"
    if not value and env.exists():
        m = re.search(r"^HOSTINGER_API_TOKEN=(.+)$", env.read_text(encoding="utf-8"), re.M)
        value = m and m.group(1).strip()
    if not value:
        sys.exit("HOSTINGER_API_TOKEN is not set (environment or .env)")
    return value


def call(method, path, tok):
    req = urllib.request.Request(f"{API}{path}", method=method, headers={
        "Authorization": f"Bearer {tok}", "Accept": "application/json",
        "User-Agent": "blueprint-infrastructure/hypervisor-backups",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        sys.exit(f"{method} {path}: HTTP {exc.code} {exc.read()[:300]!r}")


def cmd_status(tok):
    vms = call("GET", "/virtual-machines", tok)
    now = dt.datetime.now(dt.timezone.utc)
    bad = 0
    for host in HOSTS:
        vid = vm_id(vms, host)
        ok, msg = backup_verdict(call("GET", f"/virtual-machines/{vid}/backups", tok)["data"], now)
        snap = call("GET", f"/virtual-machines/{vid}/snapshot", tok)
        snap_msg = (f"snapshot {snap['created_at']}, expires {snap.get('expires_at')}"
                    if snapshot_exists(snap) else "no snapshot")
        print(f"{'ok  ' if ok else 'FAIL'} {host} ({vid}): {msg}; {snap_msg}")
        bad += not ok
    return 1 if bad else 0


def cmd_snapshot(tok, host, replace):
    vid = vm_id(call("GET", "/virtual-machines", tok), host)
    existing = call("GET", f"/virtual-machines/{vid}/snapshot", tok)
    if snapshot_exists(existing) and not replace:
        sys.exit(f"{host} already has a snapshot from {existing['created_at']}; a new one overwrites it. "
                 "Pass --replace if that is intended.")
    action = call("POST", f"/virtual-machines/{vid}/snapshot", tok)
    print(f"{host}: snapshot action {action['id']} {action.get('state')} -- polling to success", flush=True)

    def fetch():
        a = call("GET", f"/virtual-machines/{vid}/actions/{action['id']}", tok)
        print(f"  {dt.datetime.now():%H:%M:%S} {a.get('state')}", flush=True)
        return a

    try:
        done = poll_action(fetch, time.sleep, time.monotonic, interval=15, timeout=3600)
    except ActionFailed as exc:
        sys.exit(f"{host}: {exc}")
    snap = call("GET", f"/virtual-machines/{vid}/snapshot", tok)
    print(f"{host}: action {done['id']} success at {done.get('updated_at')}; "
          f"snapshot {snap['created_at']}, expires {snap.get('expires_at')}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sp = sub.add_parser("snapshot")
    sp.add_argument("host", choices=HOSTS)
    sp.add_argument("--replace", action="store_true")
    args = ap.parse_args()
    tok = token()
    if args.cmd == "status":
        return cmd_status(tok)
    return cmd_snapshot(tok, args.host, args.replace)


if __name__ == "__main__":
    sys.exit(main())
