#!/usr/bin/env python3
"""Self-check for check-backup-targets.py.  Run: python3 vps/shared/test_check_backup_targets.py

Each case builds a tiny fake repository -- a hosts.json, a stack or two, a targets file --
and asserts the checker's verdict. The cases that matter are the failures: a host with no
targets file, and a named volume nobody declared. Those are how backup coverage rots
without anyone noticing, which is the whole reason the check exists.

The last case runs the checker against this repository itself.
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import textwrap

SCRIPT = pathlib.Path(__file__).with_name("check-backup-targets.py")
REPO = SCRIPT.parents[2]


def repo(hosts, files):
    """Write a fake repo: hosts is the hosts.json list, files maps rel path -> text."""
    root = pathlib.Path(tempfile.mkdtemp())
    (root / "vps").mkdir()
    (root / "vps" / "hosts.json").write_text(json.dumps(hosts), encoding="utf-8")
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(text), encoding="utf-8")
    return root


def check(root):
    return subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)


def expect(name, root, rc, *needles):
    r = check(root)
    out = r.stdout + r.stderr
    assert r.returncode == rc, f"{name}: expected rc={rc}, got {r.returncode}\n{out}"
    for n in needles:
        assert n in out, f"{name}: expected {n!r} in output\n{out}"


H1 = [{"key": "h1", "dir": "vps/h1", "env_name": "prod"}]

DB_COMPOSE = """
    services:
      db:
        image: postgres:16-alpine
        container_name: app-db
        volumes:
          - pgdata:/var/lib/postgresql/data
          - ./init:/docker-entrypoint-initdb.d:ro
      web:
        image: nginx
        volumes:
          - type: volume
            source: assets
            target: /srv
    volumes:
      pgdata:
      assets:
        name: web-assets
"""

GOOD_TARGETS = """
    targets:
      - name: app-db
        kind: postgres
        container: app-db
        database: app
        role: postgres
        floor: 64K
      - name: assets
        kind: volume
        volume: web-assets
        floor: 1K
"""

# Covered: pgdata through the postgres target's container, web-assets as a volume.
expect("everything covered", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": GOOD_TARGETS,
}), 0)

expect("a host with no targets file fails", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
}), 1, "h1", "targets.yml")

# THE ONE THAT MATTERS: a named volume nobody declared. The compose project prefix is part
# of the real name, so the message must use it -- that is the name `docker volume ls` shows.
expect("an undeclared volume fails and is named as Docker names it", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": """
        targets:
          - {name: app-db, kind: postgres, container: app-db, database: app, role: postgres, floor: 64K}
    """,
}), 1, "web-assets", "neither backed up nor skipped")

expect("a skip with a reason covers a volume", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": """
        targets:
          - {name: app-db, kind: postgres, container: app-db, database: app, role: postgres, floor: 64K}
        skip:
          - volume: web-assets
            reason: rebuilt from the image on every deploy
    """,
}), 0)

for reason in ("", "   ", None):
    entry = {"volume": "web-assets"} if reason is None else {"volume": "web-assets", "reason": reason}
    expect(f"a skip without a reason fails ({reason!r})", repo(H1, {
        "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
        "vps/h1/stacks/backup/targets.yml": json.dumps({
            "targets": [{"name": "app-db", "kind": "postgres", "container": "app-db",
                         "database": "app", "role": "postgres", "floor": "64K"}],
            "skip": [entry]}),
    }), 1, "web-assets", "reason")

# Unnamed, non-external volumes get the compose project (the host stack dir) as a prefix.
expect("the project prefix is applied to unnamed volumes", repo(H1, {
    "vps/h1/stacks/cache/docker-compose.yml": """
        services:
          redis: {image: redis, volumes: ["data:/data"]}
        volumes:
          data:
    """,
    "vps/h1/stacks/backup/targets.yml": """
        targets:
          - {name: redis, kind: volume, volume: cache_data, floor: 1K}
    """,
}), 0)

expect("an external volume keeps its bare name", repo(H1, {
    "vps/h1/stacks/cache/docker-compose.yml": """
        services:
          redis: {image: redis, volumes: ["data:/data"]}
        volumes:
          data: {external: true}
    """,
    "vps/h1/stacks/backup/targets.yml": """
        targets:
          - {name: redis, kind: volume, volume: data, floor: 1K}
    """,
}), 0)

# A fanout stack is deployed once per destination, each with its own ENV_NAME -- so one
# compose volume is TWO Docker volumes, and each must be covered on its own.
FANOUT = [{"key": "h1", "dir": "vps/h1", "env_name": "prod",
           "fanout": {"booking": [{"dir": "booking-staging", "env_name": "staging"},
                                  {"dir": "booking-prod", "env_name": "prod"}]}}]
BOOKING = """
    services:
      db:
        image: postgres:16-alpine
        container_name: booking-db-${ENV_NAME}
        volumes: [booking_pgdata:/var/lib/postgresql/data]
    volumes:
      booking_pgdata:
        name: booking_${ENV_NAME}_pgdata
"""
expect("fanout: each destination's volume is checked separately", repo(FANOUT, {
    "vps/h1/stacks/booking/docker-compose.yml": BOOKING,
    "vps/h1/stacks/backup/targets.yml": """
        targets:
          - {name: booking-staging, kind: postgres, container: booking-db-staging, database: b, role: postgres, floor: 1K}
    """,
}), 1, "booking_prod_pgdata")

expect("fanout: both destinations covered", repo(FANOUT, {
    "vps/h1/stacks/booking/docker-compose.yml": BOOKING,
    "vps/h1/stacks/backup/targets.yml": """
        targets:
          - {name: booking-staging, kind: postgres, container: booking-db-staging, database: b, role: postgres, floor: 1K}
        skip:
          - {volume: booking_prod_pgdata, reason: fresh}
    """,
}), 0)

# Stale declarations: a target or skip that names something no compose file has any more
# is a backup set that has drifted the other way -- and for a dump target, a nightly failure.
expect("a declared volume that no compose defines fails", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": GOOD_TARGETS + """
      - {name: gone, kind: volume, volume: long-gone, floor: 1K}
    """,
}), 1, "long-gone")

expect("a skip for a volume that no compose defines fails", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": GOOD_TARGETS + """
    skip:
      - {volume: long-gone, reason: was here once}
    """,
}), 1, "long-gone")

expect("a dump target whose container no compose defines fails", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": GOOD_TARGETS + """
      - {name: other, kind: mysql, container: nowhere-db, database: x, role: root, floor: 1K}
    """,
}), 1, "nowhere-db")

expect("a volume both backed up and skipped fails", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": GOOD_TARGETS + """
    skip:
      - {volume: web-assets, reason: contradiction}
    """,
}), 1, "web-assets", "both")

expect("a host that runs the job must declare at least one target", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/docker-compose.yml": "services:\n  backup: {image: x}\n",
    "vps/h1/stacks/backup/targets.yml": json.dumps({"targets": [], "skip": [
        {"volume": "app_pgdata", "reason": "r"}, {"volume": "web-assets", "reason": "r"}]}),
}), 1, "no targets")

# A host whose backup stack has not landed yet declares only skips -- honest, and checked.
expect("a host without the job may declare only skips", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": json.dumps({"targets": [], "skip": [
        {"volume": "app_pgdata", "reason": "r"}, {"volume": "web-assets", "reason": "r"}]}),
}), 0)

# The schema the job itself enforces at runtime, caught here before a deploy instead.
for label, bad, needle in [
    ("duplicate name", {"targets": [
        {"name": "a", "kind": "volume", "volume": "web-assets", "floor": "1K"},
        {"name": "a", "kind": "volume", "volume": "web-assets", "floor": "1K"}]}, "twice"),
    ("unknown kind", {"targets": [{"name": "a", "kind": "redis", "floor": "1K"}]}, "redis"),
    ("missing role", {"targets": [
        {"name": "a", "kind": "postgres", "container": "app-db", "database": "d", "floor": "1K"}]}, "role"),
    ("missing floor", {"targets": [{"name": "a", "kind": "volume", "volume": "web-assets"}]}, "floor"),
    ("bad floor", {"targets": [{"name": "a", "kind": "volume", "volume": "web-assets", "floor": "lots"}]}, "floor"),
    ("unsafe name", {"targets": [{"name": "A B", "kind": "volume", "volume": "web-assets", "floor": "1K"}]}, "A B"),
]:
    expect(f"schema: {label}", repo(H1, {
        "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
        "vps/h1/stacks/backup/targets.yml": json.dumps(bad),
    }), 1, needle)

expect("an unresolvable variable in a volume name fails rather than guessing", repo(H1, {
    "vps/h1/stacks/cache/docker-compose.yml": """
        services:
          redis: {image: redis, volumes: ["data:/data"]}
        volumes:
          data: {name: "${SOMETHING}_data"}
    """,
    "vps/h1/stacks/backup/targets.yml": """
        targets:
          - {name: redis, kind: volume, volume: x_data, floor: 1K}
    """,
}), 1, "SOMETHING")

# A host declared out of scope. The point of these three is that an exemption is a claim
# someone made on purpose and has to keep true -- not a quiet hole where a host used to be.
OUT = [{"key": "h1", "dir": "vps/h1", "env_name": "prod",
        "no_backups": "Teeko host, out of scope (#4). Leaves n8n's database unprotected."}]

expect("an out-of-scope host needs no targets file, and its volumes are not checked", repo(OUT, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
}), 0, "out of scope for backups", "Leaves n8n's database unprotected")

expect("an out-of-scope host that still has a targets file fails", repo(OUT, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": """
        targets:
          - {name: db, kind: postgres, container: app-db, database: d, role: postgres, floor: 1K}
    """,
}), 1, "still exists")

expect("an exemption with a blank reason fails", repo(
    [{"key": "h1", "dir": "vps/h1", "env_name": "prod", "no_backups": "   "}], {
        "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    }), 1, "needs a reason")

# ── The job itself: one implementation, run on every in-scope host ─────────────────────
# Each host's backup stack carries its own copy of the job, because CI rsyncs only the stack
# directory. The copies must not drift: a fix landed on one host and not the other is a host
# still running the bug. Only crontab, the compose file, targets.yml and ci/ are per host.
H2 = [{"key": "h1", "dir": "vps/h1", "env_name": "prod"},
      {"key": "h2", "dir": "vps/h2", "env_name": "prod"}]


def job(host, cron="30 3 * * *", lib="# lib\n", extra=None):
    files = {
        f"vps/{host}/stacks/app/docker-compose.yml":
            DB_COMPOSE.replace("web-assets", f"{host}-assets").replace("app-db", f"{host}-db"),
        f"vps/{host}/stacks/backup/docker-compose.yml": "services:\n  backup: {image: x}\n",
        f"vps/{host}/stacks/backup/Dockerfile": "FROM restic/restic:0.18.1\n",
        f"vps/{host}/stacks/backup/bin/lib.sh": lib,
        f"vps/{host}/stacks/backup/bin/backup.sh": "# backup\n",
        f"vps/{host}/stacks/backup/crontab": f"# a comment, 30 3 * * *\n{cron} /app/bin/backup.sh\n",
        f"vps/{host}/stacks/backup/targets.yml": f"""
            targets:
              - {{name: db, kind: postgres, container: {host}-db, database: d, role: postgres, floor: 1K}}
              - {{name: assets, kind: volume, volume: {host}-assets, floor: 1K}}
        """,
    }
    files.update(extra or {})
    return files


expect("two hosts with the same job and staggered schedules pass", repo(H2, {
    **job("h1"), **job("h2", cron="30 4 * * *")}), 0)

expect("a job file that differs between hosts fails, naming the file", repo(H2, {
    **job("h1"), **job("h2", cron="30 4 * * *", lib="# lib, patched on h2 only\n")}), 1,
    "bin/lib.sh", "h1", "h2")

expect("a job file present on one host only fails", repo(H2, {
    **job("h1", extra={"vps/h1/stacks/backup/bin/restore-drill.sh": "# drill\n"}),
    **job("h2", cron="30 4 * * *")}), 1, "bin/restore-drill.sh")

# The hosts share one bucket and upload at night: starting together contends for bandwidth.
expect("two hosts starting at the same time fail", repo(H2, {
    **job("h1"), **job("h2")}), 1, "stagger", "30 3")

expect("the same start written differently still fails", repo(H2, {
    **job("h1", cron="30 4 * * *"), **job("h2", cron="30 04 * * *")}), 1, "stagger")

expect("a host that runs the job without a crontab fails", repo(H2, {
    **job("h1"), **{k: v for k, v in job("h2").items() if not k.endswith("crontab")}}), 1,
    "h2", "crontab")

# drill_tables: which tables the restore drill counts. Optional, database kinds only, and
# spliced into SQL -- so plain identifiers only.
for label, drill, rc, needle in [
    ("a list of identifiers is accepted", ["tenants", "wp_posts"], 0, None),
    ("an empty list fails", [], 1, "drill_tables"),
    ("a string instead of a list fails", "tenants clients", 1, "drill_tables"),
    ("an identifier with SQL in it fails", ["tenants; drop table x"], 1, "drill_tables"),
]:
    t = {"name": "db", "kind": "postgres", "container": "app-db", "database": "d",
         "role": "postgres", "floor": "1K", "drill_tables": drill}
    expect(f"drill_tables: {label}", repo(H1, {
        "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
        "vps/h1/stacks/backup/targets.yml": json.dumps({
            "targets": [t], "skip": [{"volume": "web-assets", "reason": "r"}]}),
    }), rc, *([needle] if needle else []))

expect("drill_tables on a volume target fails", repo(H1, {
    "vps/h1/stacks/app/docker-compose.yml": DB_COMPOSE,
    "vps/h1/stacks/backup/targets.yml": json.dumps({"targets": [
        {"name": "db", "kind": "postgres", "container": "app-db", "database": "d",
         "role": "postgres", "floor": "1K"},
        {"name": "a", "kind": "volume", "volume": "web-assets", "floor": "1K",
         "drill_tables": ["x"]}]}),
}), 1, "drill_tables")

# And the real thing.
r = check(REPO)
assert r.returncode == 0, f"this repository's backup targets do not check out:\n{r.stdout}{r.stderr}"

print("check-backup-targets: all cases passed")
