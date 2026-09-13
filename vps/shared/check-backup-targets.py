#!/usr/bin/env python3
"""Check that every host declares its backup set, and that the declaration matches reality.

For every host in vps/hosts.json that is in scope for backups:

  0. A host may be declared OUT of scope with `no_backups: <reason>` in vps/hosts.json. It
     then must NOT carry a targets.yml -- a file there means the scope decision and the repo
     disagree, and one of them is wrong. Exempt hosts are named in every run's output, clean
     or not, so that "all clear" can never be read as "everything is backed up". The three
     Teeko hosts are exempt (#4, #22); what that leaves unprotected is in each reason.

  1. <dir>/stacks/backup/targets.yml exists and is well formed -- the same rules the job
     enforces at runtime (bin/lib.sh load_targets), caught before a deploy instead of at
     03:30.
  2. Every named Docker volume in that host's compose files is either backed up or listed
     under `skip:` with a reason. A volume is backed up when a `volume` target names it, or
     when a `postgres`/`mysql` target dumps the container that mounts it.
  3. Nothing is declared that no compose file has any more: a stale skip hides nothing, and
     a stale target is a backup that fails every night.
  4. `drill_tables`, where a database target declares it, is a non-empty list of plain
     identifiers -- the restore drill splices them into SQL.

Across the hosts that RUN the job (a compose file beside targets.yml):

  5. The job is one implementation. CI rsyncs only a stack's own directory, so each host
     carries a copy of the Dockerfile and bin/ -- and those copies must be identical. A fix
     that reached one host and not the other leaves that host running the bug.
  6. No two hosts start at the same time. They upload to one bucket at night; the schedule
     is the first line of each host's crontab.

Volume names are resolved the way Docker names them -- `name:` if set, the bare key if
external, otherwise `<project>_<key>` where the project is the stack's directory on the
host -- and once per fanout destination, with that destination's ENV_NAME. That is what
`docker volume ls` shows, so it is what the targets file must say.

Usage: check-backup-targets.py [repo-root]     exit 0 clean, 1 problems found
Tested by vps/shared/test_check_backup_targets.py.
"""
import json
import os
import pathlib
import re
import sys

import yaml

KINDS = {"postgres": ("container", "database", "role"),
         "mysql": ("container", "database", "role"),
         "volume": ("volume",),
         # The mail store: `container` is the server the job STOPS around the snapshot.
         "stalwart": ("container", "volume")}
NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SIZE = re.compile(r"^[0-9]+[KMG]?$")
VAR = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
COMPOSE_FILES = ("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml")
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def substitute(value, env, where, problems):
    """Resolve ${ENV_NAME}; anything else cannot be known here, so it is a problem, not a guess."""
    def sub(m):
        if m.group(1) in env:
            return env[m.group(1)]
        problems.append(f"{where}: cannot resolve ${{{m.group(1)}}} in {value!r}")
        return m.group(0)
    return VAR.sub(sub, str(value))


def compose_inventory(host, problems):
    """-> ({volume name: stack}, {container name: set of volume names})"""
    volumes, mounts = {}, {}
    stacks_dir = pathlib.Path(host["dir"]) / "stacks"
    fanout = host.get("fanout") or {}
    for stack_dir in sorted(p for p in stacks_dir.iterdir() if p.is_dir()):
        files = [stack_dir / f for f in COMPOSE_FILES if (stack_dir / f).is_file()]
        if not files:
            continue
        doc = yaml.safe_load(files[0].read_text(encoding="utf-8")) or {}
        stack = stack_dir.name
        for dest in fanout.get(stack, [{"dir": stack, "env_name": host.get("env_name", "")}]):
            env = {"ENV_NAME": dest.get("env_name") or host.get("env_name", "")}
            where = f"{host['key']}: {files[0].as_posix()} ({dest['dir']})"
            project = doc.get("name") or dest["dir"]
            names = {}
            for key, spec in (doc.get("volumes") or {}).items():
                spec = spec or {}
                if spec.get("name"):
                    name = substitute(spec["name"], env, where, problems)
                elif spec.get("external"):
                    name = key
                else:
                    name = f"{project}_{key}"
                names[key] = name
                volumes[name] = dest["dir"]
            for svc_key, svc in (doc.get("services") or {}).items():
                container = substitute(svc.get("container_name") or f"{project}-{svc_key}-1",
                                       env, where, problems)
                used = mounts.setdefault(container, set())
                for m in svc.get("volumes") or []:
                    source = m.get("source") if isinstance(m, dict) else str(m).split(":", 1)[0]
                    if source in names:
                        used.add(names[source])
    return volumes, mounts


def check_host(host, problems):
    key = host["key"]
    path = pathlib.Path(host["dir"]) / "stacks" / "backup" / "targets.yml"
    if host.get("no_backups"):
        # Out of scope by decision. Demand a reason -- an exemption nobody justified is
        # indistinguishable from one nobody noticed -- and refuse a leftover targets file,
        # which would mean the repo still declares a backup set for a host we do not back up.
        if not str(host["no_backups"]).strip():
            problems.append(f"{key}: no_backups needs a reason -- say what it leaves unprotected")
        if path.is_file():
            problems.append(f"{key}: declared no_backups but {path.as_posix()} still exists -- "
                            "delete it, or drop no_backups")
        return
    if not path.is_file():
        problems.append(f"{key}: no {path.as_posix()} -- every host declares what it backs up, "
                        "even if that is only skips")
        return
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    where = f"{key}: {path.as_posix()}"
    targets = doc.get("targets") or []
    skips = doc.get("skip") or []
    # A host whose backup stack has not landed yet may declare only skips. A host that
    # RUNS the job may not: a job that backs up nothing must not look like one that succeeded.
    runs_job = any((path.parent / f).is_file() for f in COMPOSE_FILES)
    if not targets and runs_job:
        problems.append(f"{where}: declares no targets, but this host runs the backup job")

    seen = set()
    for t in targets:
        name = str(t.get("name", ""))
        if not NAME.match(name):
            problems.append(f"{where}: target name {name!r} must be lowercase letters, digits and -")
        if name in seen:
            problems.append(f"{where}: target name {name!r} is declared twice")
        seen.add(name)
        kind = t.get("kind")
        if kind not in KINDS:
            problems.append(f"{where}: {name}: unknown kind {kind!r} (postgres, mysql, volume or stalwart)")
        else:
            for field in KINDS[kind]:
                if not str(t.get(field) or "").strip():
                    problems.append(f"{where}: {name}: {kind} needs a {field}")
        floor = str(t.get("floor") or "")
        if not SIZE.match(floor) or int(floor.rstrip("KMG")) == 0:
            problems.append(f"{where}: {name}: floor {floor!r} is not a size (e.g. 1024, 280K, 1M)")
        if "drill_tables" in t:
            drill = t["drill_tables"]
            if kind not in ("postgres", "mysql"):
                problems.append(f"{where}: {name}: drill_tables is for postgres and mysql targets only")
            elif (not isinstance(drill, list) or not drill
                  or not all(isinstance(d, str) and IDENTIFIER.match(d) for d in drill)):
                problems.append(f"{where}: {name}: drill_tables must be a non-empty list of plain "
                                f"table names, got {drill!r}")

    volumes, mounts = compose_inventory(host, problems)

    backed_up = {}
    for t in targets:
        if t.get("kind") == "volume" and t.get("volume"):
            backed_up[t["volume"]] = t.get("name")
            if t["volume"] not in volumes:
                problems.append(f"{where}: {t.get('name')}: volume {t['volume']!r} is in no compose file")
        elif t.get("kind") == "stalwart" and t.get("volume") and t.get("container"):
            # Snapshotted only while `container` is stopped -- so that container must be the
            # one holding the store open, or the snapshot reads a live store after all.
            backed_up[t["volume"]] = t.get("name")
            if t["volume"] not in volumes:
                problems.append(f"{where}: {t.get('name')}: volume {t['volume']!r} is in no compose file")
            if t["container"] not in mounts:
                problems.append(f"{where}: {t.get('name')}: container {t['container']!r} is in no compose file")
            elif t["volume"] not in mounts[t["container"]]:
                problems.append(f"{where}: {t.get('name')}: container {t['container']!r} does not mount "
                                f"{t['volume']!r} -- stopping it would not make the store consistent")
        elif t.get("kind") in ("postgres", "mysql") and t.get("container"):
            if t["container"] not in mounts:
                problems.append(f"{where}: {t.get('name')}: container {t['container']!r} is in no compose file")
            for v in mounts.get(t["container"], ()):
                backed_up[v] = t.get("name")

    skipped = set()
    for s in skips:
        vol = str((s or {}).get("volume") or "")
        if not str((s or {}).get("reason") or "").strip():
            problems.append(f"{where}: skip of {vol!r} has no reason -- say why it is safe to lose")
        if vol not in volumes:
            problems.append(f"{where}: skip of {vol!r} names a volume that is in no compose file")
        if vol in backed_up:
            problems.append(f"{where}: {vol!r} is both backed up (by {backed_up[vol]}) and skipped")
        skipped.add(vol)

    for vol, stack in sorted(volumes.items()):
        if vol not in backed_up and vol not in skipped:
            problems.append(f"{where}: volume {vol!r} (stack {stack}) is neither backed up nor skipped")


def job_files(stack):
    """-> {relative path: bytes} for the parts of the job every host must share."""
    paths = [stack / "Dockerfile"] + sorted(p for p in (stack / "bin").rglob("*") if p.is_file())
    return {p.relative_to(stack).as_posix(): p.read_bytes() for p in paths if p.exists()}


def schedule(crontab):
    """-> the five schedule fields of the first job line, numbers normalised, or None.

    Normalised so that `30 04` and `30 4` are recognised as the same start time."""
    for line in crontab.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if fields and not fields[0].startswith("#") and len(fields) > 5:
            return " ".join(str(int(f)) if f.isdigit() else f for f in fields[:5])
    return None


def check_jobs(hosts, problems):
    running = []
    for h in hosts:
        stack = pathlib.Path(h["dir"]) / "stacks" / "backup"
        if not h.get("no_backups") and any((stack / f).is_file() for f in COMPOSE_FILES):
            running.append((h["key"], stack))

    copies = {key: job_files(stack) for key, stack in running}
    for path in sorted({p for files in copies.values() for p in files}):
        variants = {}
        for key, files in copies.items():
            variants.setdefault(files.get(path), []).append(key)
        if len(variants) > 1:
            where = "; ".join(f"{'missing' if body is None else 'one copy'} on {', '.join(keys)}"
                              for body, keys in variants.items())
            problems.append(f"backup job drift: stacks/backup/{path} differs between hosts ({where}) "
                            "-- the job is one implementation, copy the change to every host")

    starts = {}
    for key, stack in running:
        when = schedule(stack / "crontab") if (stack / "crontab").is_file() else None
        if when is None:
            problems.append(f"{key}: runs the backup job but {(stack / 'crontab').as_posix()} "
                            "has no schedule")
            continue
        starts.setdefault(when, []).append(key)
    for when, keys in starts.items():
        if len(keys) > 1:
            problems.append(f"backup schedules must stagger: {', '.join(keys)} all start at "
                            f"'{when}' and would contend for upload bandwidth")


def main():
    os.chdir(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve())
    problems = []
    hosts = json.loads(pathlib.Path("vps/hosts.json").read_text(encoding="utf-8"))
    for host in hosts:
        check_host(host, problems)
    check_jobs(hosts, problems)
    for p in problems:
        print(p)

    # Print the exemptions whatever the verdict. A run that says only "all clear" while three
    # hosts sit silently out of scope is the exact failure this check exists to prevent.
    exempt = [h for h in hosts if h.get("no_backups")]
    if exempt:
        print(f"out of scope for backups ({len(exempt)} host(s)) -- NOT backed up:")
        for h in exempt:
            print(f"  {h['key']}: {h['no_backups']}")

    if problems:
        print(f"{len(problems)} backup-target problem(s)")
        return 1
    in_scope = len(hosts) - len(exempt)
    print(f"backup targets: {in_scope} host(s) in scope, each declared, every volume accounted for")
    return 0


if __name__ == "__main__":
    sys.exit(main())
