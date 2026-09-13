#!/usr/bin/env python3
"""Check that what monitoring collects, shows and alerts on still agree with each other.

For every host in vps/hosts.json that has a stacks/monitoring/ directory:

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
FAMILY = re.compile(r"^(node|container|machine|backup|textfile)_")
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


def check_host(host, by_file, by_rule, problems):
    key = host["key"]
    stack = pathlib.Path(host["dir"]) / "stacks" / "monitoring"
    if not stack.is_dir():
        return
    # The `host` label on every metric and log line is MONITORING_HOST, and every rule matches
    # host="<key>". Were they to differ, each absent_over_time would match nothing and the
    # down rule would fire for every container, forever.
    compose = [stack / f for f in COMPOSE_FILES if (stack / f).is_file()]
    doc = yaml.safe_load(compose[0].read_text(encoding="utf-8")) or {} if compose else {}
    labels = {str((svc or {}).get("environment", {}).get("MONITORING_HOST"))
              for svc in (doc.get("services") or {}).values()
              if isinstance((svc or {}).get("environment"), dict)}
    if labels != {key}:
        problems.append(f"{key}: {stack.as_posix()}: the agent must set MONITORING_HOST: {key} "
                        f"(found {sorted(labels - {'None'}) or 'none'}) -- rules match host=\"{key}\"")
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

    uid = f"container-down-{key}"
    if uid not in by_rule:
        problems.append(f"{key}: no alert rule with uid {uid} under grafana/rules/ -- "
                        "every monitored host declares its containers")
        return
    expr = "\n".join(by_rule[uid])
    declared = set(CONTAINER.findall(expr))
    selectors = re.findall(r"\{[^}]*\}", expr)
    for sel in selectors:
        if f'host="{key}"' not in sel:
            problems.append(f'{key}: {uid}: selector {sel} has no host="{key}" matcher -- '
                            "it would match a container of that name on any host")
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
    for host in json.loads(pathlib.Path("vps/hosts.json").read_text(encoding="utf-8")):
        check_host(host, by_file, by_rule, problems)
    for p in problems:
        print(p)
    if problems:
        print(f"{len(problems)} monitoring problem(s)")
        return 1
    print("monitoring: allowlist, panels, rules and declared containers agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
