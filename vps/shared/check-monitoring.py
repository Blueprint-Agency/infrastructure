#!/usr/bin/env python3
"""Check that what monitoring collects, shows and alerts on still agree with each other.

For every host in vps/hosts.json:

  0. It has a stacks/monitoring/ directory, unless it declares `no_monitoring: <reason>` -- and
     then it must NOT have one. Exempt hosts are printed on every run, clean or not, so "all
     clear" never reads as "every host is watched" (#25). The three Teeko hosts are exempt.

For every monitored host:

  1. Every metric in its metrics.allowlist is read by at least one dashboard panel or alert
     rule under grafana/. A metric nothing reads is series budget spent on nothing (#22).
  2. Every node_* / container_* / machine_* metric a panel or rule reads is in the allowlist.
     Otherwise the agent drops it before it leaves the host: an empty panel, or a rule that
     can never fire.
  3. The alert rule `container-down-<host>` declares exactly the containers that host's
     compose files name -- fanout resolved per destination, the monitoring stack itself
     exempt (an agent cannot report its own absence) -- and every one of its selectors
     carries host="<host>". A container nobody declared dies silently; a selector without
     the host matcher names an instance on the wrong machine.
  4. The other rules that watch for silence exist for it too -- probes-stale-<host>, and
     backup-stale-<host> where it runs the backup job -- every agent-collected metric in them
     pinned to host="<host>". absent_over_time without the host is satisfied by another host.

Across monitored hosts:

  5. The stack is one implementation: every file except the compose file and ci/ is identical
     on every host. CI rsyncs only a stack's own dir, so a fix in one copy is a bug in the other.

Off-platform checks (#37):

  6. Every name under `off_platform:` in grafana/synthetic/endpoints.yml -- booking-system's
     Vercel frontends, which no router here serves -- reaches an alert. Those checks carry
     `host: <platform>`, not a VPS key, so the moment someone pins grafana/rules/endpoints.yml
     to host="bpvps1" to quieten something, every off-platform check is probed and alerted on
     by nothing, and the file still looks correct.

Container names are resolved the way check-backup-targets.py resolves them: container_name
with ${ENV_NAME} per fanout destination, else <project>-<service>-1.

Usage: check-monitoring.py [repo-root]     exit 0 clean, 1 problems found
Tested by vps/shared/test_check_monitoring.py.
"""
import json
import os
import pathlib
import re
import sys

import yaml

COMPOSE_FILES = ("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml")
VAR = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
TOKEN = re.compile(r"[A-Za-z_:][A-Za-z0-9_:]*")
METRIC = re.compile(r"^[A-Za-z_:][A-Za-z0-9_:]*$")
# The families the agent collects. Only these are checked against the allowlist, so that
# PromQL functions (absent_over_time) and label names (compose_project) are not read as metrics.
# After the exporters' own families come the textfile producers' prefixes -- a new producer
# adds its prefix here (docs/textfile-metrics.md). probe_* / sm_* are NOT the agent's: Grafana's
# synthetic probes write them straight to Grafana Cloud.
FAMILY = re.compile(r"^(node|container|machine|backup|textfile|probes|docker|postgres|tailscale|mail)_")
TEXTFILE_VOLUME, TEXTFILE_DIR = "monitoring_textfile", "/textfile"
CONTAINER = re.compile(r'container="([^"]+)"')


def queries(node):
    """Every PromQL string in a dashboard or rule document: values of `expr` and `query` keys."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k in ("expr", "query") and isinstance(v, str):
                yield v
            else:
                yield from queries(v)
    elif isinstance(node, list):
        for v in node:
            yield from queries(v)


def load_grafana():
    """-> ({source file: [query]}, {rule uid: [query]})"""
    by_file, by_rule = {}, {}
    root = pathlib.Path("grafana")
    for path in sorted(root.rglob("*")) if root.is_dir() else ():
        if path.suffix == ".json":
            doc = json.loads(path.read_text(encoding="utf-8"))
        elif path.suffix in (".yml", ".yaml"):
            doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            for group in doc.get("groups") or []:
                for rule in group.get("rules") or []:
                    by_rule[rule.get("uid")] = list(queries(rule.get("data")))
        else:
            continue
        by_file[path.as_posix()] = list(queries(doc))
    return by_file, by_rule


def compose_containers(host, problems):
    """-> {container name: stack dir} for every stack except monitoring."""
    containers = {}
    fanout = host.get("fanout") or {}
    for stack_dir in sorted(p for p in (pathlib.Path(host["dir"]) / "stacks").iterdir() if p.is_dir()):
        files = [stack_dir / f for f in COMPOSE_FILES if (stack_dir / f).is_file()]
        if not files or stack_dir.name == "monitoring":
            continue
        doc = yaml.safe_load(files[0].read_text(encoding="utf-8")) or {}
        for dest in fanout.get(stack_dir.name, [{"dir": stack_dir.name, "env_name": host.get("env_name", "")}]):
            env = {"ENV_NAME": dest.get("env_name") or host.get("env_name", "")}
            project = doc.get("name") or dest["dir"]
            for key, svc in (doc.get("services") or {}).items():
                raw = (svc or {}).get("container_name") or f"{project}-{key}-1"

                def sub(m):
                    if m.group(1) in env:
                        return env[m.group(1)]
                    problems.append(f"{host['key']}: {files[0].as_posix()}: cannot resolve "
                                    f"${{{m.group(1)}}} in container_name {raw!r}")
                    return m.group(0)
                containers[VAR.sub(sub, raw)] = dest["dir"]
    return containers


def check_textfile(key, stack, doc, problems):
    """The agent's half of the textfile seam (docs/textfile-metrics.md): the shared volume
    mounted read-only at /textfile, and the textfile collector pointed at it. Missing either,
    every producer's file is written and never read, and its staleness rule blames the producer."""
    names = {k: (v or {}).get("name", k) for k, v in (doc.get("volumes") or {}).items()}
    mounts = []  # (source, target, read-only), short or long compose syntax
    for svc in (doc.get("services") or {}).values():
        for m in (svc or {}).get("volumes") or []:
            if isinstance(m, dict):
                mounts.append((m.get("source"), m.get("target"), bool(m.get("read_only"))))
            elif isinstance(m, str) and m.count(":") >= 1:
                parts = m.split(":")
                mounts.append((parts[0], parts[1], len(parts) > 2 and "ro" in parts[2].split(",")))
    found = [ro for src, dst, ro in mounts if dst == TEXTFILE_DIR and names.get(src) == TEXTFILE_VOLUME]
    if not found:
        problems.append(f"{key}: {stack.as_posix()}: the agent does not mount the {TEXTFILE_VOLUME} volume "
                        f"at {TEXTFILE_DIR} -- textfile producers would write and nothing would read")
    elif not any(found):
        problems.append(f"{key}: {stack.as_posix()}: mount {TEXTFILE_VOLUME} at {TEXTFILE_DIR} read-only "
                        "-- the agent reads producers' files, it never writes them")
    config = stack / "config.alloy"
    if not config.is_file():
        problems.append(f"{key}: no {config.as_posix()} -- the agent has no config to read textfiles with")
        return
    text = config.read_text(encoding="utf-8")
    if not re.search(r'set_collectors\s*=\s*\[[^\]]*"textfile"', text) or \
            not re.search(r'textfile\s*\{[^}]*directory\s*=\s*"' + re.escape(TEXTFILE_DIR) + '"', text):
        problems.append(f"{key}: {config.as_posix()}: enable the textfile collector with directory = "
                        f"\"{TEXTFILE_DIR}\" in prometheus.exporter.unix")


def host_selectors(key, uid, queries_, problems):
    """Every selector in a per-host rule must carry host="<key>". -> the rule's joined PromQL."""
    expr = "\n".join(queries_)
    for m in re.finditer(r"([A-Za-z_:][A-Za-z0-9_:]*)\s*(\{[^}]*\})?", expr):
        name, sel = m.group(1), m.group(2) or ""
        if FAMILY.match(name) and f'host="{key}"' not in sel:
            problems.append(f'{key}: {uid}: {name}{sel} has no host="{key}" matcher -- '
                            "it would match that series on any host")
    return expr


def agent_files(stack):
    """-> {relative path: bytes} for the parts of the agent every host must share: everything
    in the stack except its compose file (which names the host) and ci/."""
    return {p.relative_to(stack).as_posix(): p.read_bytes() for p in sorted(stack.rglob("*"))
            if p.is_file() and p.name not in COMPOSE_FILES and "ci" not in p.relative_to(stack).parts[:1]}


def check_drift(hosts, problems):
    copies = {h["key"]: agent_files(pathlib.Path(h["dir"]) / "stacks" / "monitoring") for h in hosts
              if not h.get("no_monitoring") and (pathlib.Path(h["dir"]) / "stacks" / "monitoring").is_dir()}
    for path in sorted({p for files in copies.values() for p in files}):
        variants = {}
        for key, files in copies.items():
            variants.setdefault(files.get(path), []).append(key)
        if len(variants) > 1:
            where = "; ".join(f"{'missing' if body is None else 'one copy'} on {', '.join(keys)}"
                              for body, keys in variants.items())
            problems.append(f"monitoring drift: stacks/monitoring/{path} differs between hosts ({where}) "
                            "-- the agent is one implementation, copy the change to every host")


SYNTHETIC = "grafana/synthetic/endpoints.yml"
# The rules an off-platform check depends on: all of them read probe_* / sm_check_info for every
# job. `endpoint-down` is a PREFIX, not a uid: since #42 there is one rule per cadence
# (endpoint-down-2m, endpoint-down-15m), and an off-platform name is covered by whichever
# matches its own. Requiring a literal `endpoint-down` here would fail on a correct file.
EXTERNAL_RULE_PREFIXES = ("endpoint-down", "tls-expiry")


def check_off_platform(by_rule, hosts, problems):
    """6. The names nothing here serves are still alerted on (#37)."""
    path = pathlib.Path(SYNTHETIC)
    off = (yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get("off_platform") if path.is_file() else None
    if not off:
        return
    keys = {h["key"] for h in hosts}
    platforms = sorted({str((e or {}).get("platform") or "?") for e in off.values()})
    for prefix in EXTERNAL_RULE_PREFIXES:
        uids = sorted(u for u in by_rule if str(u).startswith(prefix))
        if not uids:
            problems.append(f"{SYNTHETIC}: {len(off)} off-platform name(s) declared but no alert rule "
                            f"{prefix}* under grafana/rules/ -- they would be probed and never alerted on")
            continue
        for uid in uids:
            expr = "\n".join(by_rule[uid])
            for key in sorted(k for k in keys if f'host="{k}"' in expr):
                problems.append(f"{uid}: pinned to host=\"{key}\" -- an off-platform check's host label "
                                f"is its platform ({', '.join(platforms)}), so {', '.join(sorted(off))} "
                                "would be probed and never alerted on")


def check_host(host, by_file, by_rule, problems):
    key = host["key"]
    stack = pathlib.Path(host["dir"]) / "stacks" / "monitoring"
    if "no_monitoring" in host:
        if not str(host["no_monitoring"]).strip():
            problems.append(f"{key}: no_monitoring needs a reason -- say what goes unwatched")
        if stack.is_dir():
            problems.append(f"{key}: declared no_monitoring but {stack.as_posix()} exists -- "
                            "delete it, or drop no_monitoring")
        return
    if not stack.is_dir():
        problems.append(f"{key}: no monitoring stack at {stack.as_posix()} -- every host is monitored "
                        "unless vps/hosts.json declares no_monitoring: <reason>")
        return
    # The `host` label on every metric and log line is MONITORING_HOST, and every rule matches
    # host="<key>". Were they to differ, each absent_over_time would match nothing and the
    # down rule would fire for every container, forever.
    compose = [stack / f for f in COMPOSE_FILES if (stack / f).is_file()]
    doc = yaml.safe_load(compose[0].read_text(encoding="utf-8")) or {} if compose else {}
    # Only the agent sets it; the probes service beside it has no label of its own to stamp.
    labels = {str(svc["environment"]["MONITORING_HOST"])
              for svc in (doc.get("services") or {}).values()
              if isinstance((svc or {}).get("environment"), dict) and "MONITORING_HOST" in svc["environment"]}
    if labels != {key}:
        problems.append(f"{key}: {stack.as_posix()}: the agent must set MONITORING_HOST: {key} "
                        f"(found {sorted(labels) or 'none'}) -- rules match host=\"{key}\"")
    check_textfile(key, stack, doc, problems)
    path = stack / "metrics.allowlist"
    if not path.is_file():
        problems.append(f"{key}: no {path.as_posix()} -- the agent keeps only what it lists")
        return
    # Alloy joins these lines with | into a single keep-regex (config.alloy), so a line that
    # is not a bare metric name -- a comment, a blank, a stray ( -- silently changes the regex.
    allowed = set()
    for n, line in enumerate(path.read_text(encoding="utf-8").strip().splitlines(), 1):
        if METRIC.match(line):
            allowed.add(line)
        else:
            problems.append(f"{key}: {path.as_posix()}: line {n} {line!r} is not a metric name "
                            "-- one bare name per line, no comments or blank lines")

    read = {}
    for source, qs in by_file.items():
        for q in qs:
            for tok in TOKEN.findall(q):
                read.setdefault(tok, set()).add(source)
    for metric in sorted(allowed):
        if metric not in read:
            problems.append(f"{key}: {path.as_posix()}: {metric} is read by no panel or rule "
                            "under grafana/ -- drop it, or add the panel that needs it")
    for metric in sorted(m for m in read if FAMILY.match(m) and m not in allowed):
        for source in sorted(read[metric]):
            problems.append(f"{key}: {source} reads {metric}, which is not in {path.as_posix()} "
                            "-- the agent drops it before it leaves the host")

    # Silence can only be noticed by a rule that names the host: absent_over_time without a host
    # matcher is satisfied by the OTHER host's series. So these are written once per host.
    wanted = ["probes-stale"] + (["backup-stale"] if any(
        (pathlib.Path(host["dir"]) / "stacks" / "backup" / f).is_file() for f in COMPOSE_FILES) else [])
    for prefix in wanted:
        uid = f"{prefix}-{key}"
        if uid not in by_rule:
            problems.append(f"{key}: no alert rule with uid {uid} under grafana/rules/ -- "
                            "a monitored host carries its own staleness rules")
        else:
            host_selectors(key, uid, by_rule[uid], problems)

    uid = f"container-down-{key}"
    if uid not in by_rule:
        problems.append(f"{key}: no alert rule with uid {uid} under grafana/rules/ -- "
                        "every monitored host declares its containers")
        return
    expr = host_selectors(key, uid, by_rule[uid], problems)
    declared = set(CONTAINER.findall(expr))
    expected = compose_containers(host, problems)
    for c in sorted(set(expected) - declared):
        problems.append(f"{key}: {uid}: container {c!r} (stack {expected[c]}) is not declared "
                        "-- it could stop without an alert")
    for c in sorted(declared - set(expected)):
        problems.append(f"{key}: {uid}: container {c!r} is in no compose file on this host")


def main():
    os.chdir(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve())
    problems = []
    by_file, by_rule = load_grafana()
    hosts = json.loads(pathlib.Path("vps/hosts.json").read_text(encoding="utf-8"))
    for host in hosts:
        check_host(host, by_file, by_rule, problems)
    check_drift(hosts, problems)
    check_off_platform(by_rule, hosts, problems)
    for p in problems:
        print(p)
    # Printed whatever the verdict: "all clear" must never read as "every host is watched".
    exempt = [h for h in hosts if h.get("no_monitoring")]
    if exempt:
        print(f"out of scope for monitoring ({len(exempt)} host(s)) -- NOT monitored:")
        for h in exempt:
            print(f"  {h['key']}: {h['no_monitoring']}")
    if problems:
        print(f"{len(problems)} monitoring problem(s)")
        return 1
    print("monitoring: allowlist, panels, rules and declared containers agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
