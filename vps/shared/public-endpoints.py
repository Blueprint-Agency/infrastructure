#!/usr/bin/env python3
"""The public names this platform serves, and the external checks that watch them (#24).

The list is DERIVED, never kept by hand: every Host(`...`) in a Traefik router on an in-scope
host -- compose labels, fanout resolved per destination, and the file provider's dynamic/*.yml --
cross-checked against apps/registry.yml. grafana/synthetic/endpoints.yml holds only what the
repository cannot know: the values of ${VARS} that live in host .env files, and per-name
exceptions (a path to probe, or a skip with its reason).

One thing is not derivable at all: a name we are responsible for that we do not host, so no
router here mentions it -- booking-system's two Vercel frontends (#37). Those are typed by hand
under `off_platform:`, each with a mandatory reason and the platform that serves it, in a block
of their own so the derived list stays the source of truth for everything self-hosted.

A host is in scope unless vps/hosts.json declares it `no_backups: <reason>` -- the Teeko hosts,
out of scope for backups and monitoring alike (#4, #22).

Fails when:
  - a registry domain on an in-scope host is served by no router on that host (drift);
  - a router's ${VAR} has no value in endpoints.yml (a name nobody can probe);
  - a registry domain is skipped (every registry domain has a check);
  - a skip has no reason, or an endpoints.yml entry names no router (exceptions that rot);
  - an off_platform entry has no reason or no platform, names a platform that is a VPS host
    key, is also under endpoints:, or names something a router here DOES serve (in which case
    it is derived already and the hand-typed copy is the one that will rot).

Usage: public-endpoints.py [repo-root] [--json]
  exit 0 clean, 1 problems found. --json prints the checks scripts/grafana-apply.py creates.
Tested by vps/shared/test_public_endpoints.py.
"""
import json
import os
import pathlib
import re
import sys

import yaml

COMPOSE_FILES = ("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml")
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
# Host(`a`) only -- HostRegexp / HostSNI are catch-alls or TCP, not a name a browser visits.
HOST = re.compile(r"(?<![A-Za-z])Host\(`([^`]+)`\)")
# Host(`a`, `b`): accepted by YAML and the file provider, then the router fails to build on
# Traefik v3.3 and every name on it 404s (CLAUDE.md). Reported, never silently read as no names.
MULTI_HOST = re.compile(r"(?<![A-Za-z])Host\(`[^`]*`\s*,")
ROUTER_RULE = re.compile(r"^traefik\.http\.routers\.[^.]+\.rule$")


def load_yaml(path):
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def label_rules(labels):
    items = labels.items() if isinstance(labels, dict) else (
        str(l).split("=", 1) for l in labels or [] if "=" in str(l))
    return [str(v) for k, v in items if ROUTER_RULE.match(str(k).strip())]


def dynamic_rules(doc):
    routers = ((doc.get("http") or {}).get("routers") or {}) if isinstance(doc, dict) else {}
    return [str(r.get("rule", "")) for r in routers.values() if isinstance(r, dict)]


def router_names(host, variables, problems):
    """-> {hostname: source} for every router on an in-scope host, variables resolved."""
    names = {}
    fanout = host.get("fanout") or {}
    stacks = pathlib.Path(host["dir"]) / "stacks"
    for stack in sorted(p for p in stacks.iterdir() if p.is_dir()) if stacks.is_dir() else ():
        found = []  # (rule, source file)
        for f in COMPOSE_FILES:
            if (stack / f).is_file():
                for svc in (load_yaml(stack / f).get("services") or {}).values():
                    found += [(r, stack / f) for r in label_rules((svc or {}).get("labels"))]
        for f in sorted((stack / "dynamic").glob("*.y*ml")):
            found += [(r, f) for r in dynamic_rules(load_yaml(f))]
        for dest in fanout.get(stack.name, [{"dir": stack.name}]):
            env = {**variables.get("*", {}), **variables.get(f"{host['key']}/{dest['dir']}", {}),
                   "ENV_NAME": dest.get("env_name") or host.get("env_name", "")}
            for rule, source in found:
                if MULTI_HOST.search(rule):
                    problems.append(f"{host['key']}: {source.as_posix()}: {rule!r} -- Host() takes one name "
                                    "on Traefik v3.3; write Host(`a`) || Host(`b`)")
                for raw in HOST.findall(rule):
                    missing = [v for v in VAR.findall(raw) if not env.get(v)]
                    if "$" in VAR.sub("", raw):
                        problems.append(f"{host['key']}: {source.as_posix()}: Host(`{raw}`) -- only plain "
                                        "${VAR} can be resolved here")
                        continue
                    if missing:
                        problems.append(
                            f"{host['key']}: {source.as_posix()}: Host(`{raw}`) needs "
                            f"{', '.join('${' + v + '}' for v in missing)} for {host['key']}/{dest['dir']} "
                            "-- add it under vars: in grafana/synthetic/endpoints.yml")
                        continue
                    names[VAR.sub(lambda m: str(env[m.group(1)]), raw)] = source.as_posix()
    return names


def registry_domains(in_scope, problems):
    """-> [(hostname, host key, app name)] for registry domains deployed on an in-scope host."""
    out = []
    for section in load_yaml(pathlib.Path("apps/registry.yml")).values():
        for app in section if isinstance(section, list) else ():
            vps, domain = app.get("vps") or {}, app.get("domain") or {}
            if not isinstance(vps, dict) or not isinstance(domain, dict):
                # A list of hosts cannot say which domain is on which. Out of scope it is only
                # history (drizzle-gateway); on an in-scope host it would escape the check.
                if isinstance(vps, list) and set(vps) & set(in_scope):
                    problems.append(f"apps/registry.yml: {app.get('name')}: vps is a list -- write it as "
                                    "{environment: host} matching domain:, so each domain's host is known")
                continue
            for env, name in domain.items():
                if name and vps.get(env) in in_scope:
                    out.append((str(name), vps[env], app.get("name")))
    return out


CONFIG = "grafana/synthetic/endpoints.yml"
DURATION = re.compile(r"[0-9]+[smh]")


def url_for(name, path):
    path = str(path or "/")
    return f"https://{name}{path if path.startswith('/') else '/' + path}"


def off_platform_checks(entries, served, overrides, host_keys, problems):
    """The hand-typed half: names nothing here serves, so nothing here can derive them (#37).

    Every failure below is a way one of these rots unnoticed -- an exception with no stated
    reason, a `host` label that sends someone to ssh a machine that is fine, or a duplicate of
    a name the derived list already covers and will keep covering after this entry goes stale.
    """
    checks = []
    for name, entry in sorted(entries.items()):
        entry = entry or {}
        where = f"{CONFIG}: {name}"
        if not str(entry.get("reason") or "").strip():
            problems.append(f"{where}: off_platform needs a reason -- say who serves it and why no "
                            "router here does, the same way skip: does")
        platform = str(entry.get("platform") or "").strip()
        if not platform:
            problems.append(f"{where}: off_platform needs platform: <who serves it> -- it becomes the "
                            "check's `host` label, which every alert and every silence names")
        elif platform in host_keys:
            problems.append(f"{where}: platform: {platform} is a host in vps/hosts.json, which does not "
                            "serve this name -- the alert would send someone to ssh a healthy machine")
        if name in served:
            problems.append(f"{where}: is served by a router on {served[name]} -- it is derived already; "
                            "delete the off_platform entry rather than keep a hand-typed copy")
        if name in overrides:
            problems.append(f"{where}: is under both endpoints: and off_platform: -- one name, one "
                            "declaration, or the two will disagree")
        if entry.get("frequency") is not None and not DURATION.fullmatch(str(entry["frequency"])):
            problems.append(f"{where}: frequency {entry['frequency']!r} -- expected e.g. 60s, 5m")
        probes = entry.get("probes")
        if probes is not None and not (isinstance(probes, list) and probes
                                       and all(isinstance(p, str) and p.strip() for p in probes)):
            problems.append(f"{where}: probes must be a non-empty list of probe names, or absent to "
                            f"use the file-wide probes: -- got {probes!r}")
        check = {"hostname": name, "host": platform, "url": url_for(name, entry.get("path")),
                 "off_platform": True}
        if isinstance(probes, list) and probes:
            check["probes"] = [str(p) for p in probes]
        if entry.get("frequency") is not None:
            check["frequency"] = str(entry["frequency"])
        checks.append(check)
    return checks


def derive(problems):
    """-> [check] where a check is {hostname, host, url} and, off-platform only, probes/frequency."""
    config = pathlib.Path(CONFIG)
    doc = load_yaml(config) if config.is_file() else {}
    variables, overrides = doc.get("vars") or {}, doc.get("endpoints") or {}
    off = doc.get("off_platform") or {}
    hosts = json.loads(pathlib.Path("vps/hosts.json").read_text(encoding="utf-8"))
    in_scope = {h["key"]: h for h in hosts if not h.get("no_backups")}

    served = {}  # hostname -> host key
    for key, host in in_scope.items():
        for name in router_names(host, variables, problems):
            if served.setdefault(name, key) != key:
                problems.append(f"{name} has a router on both {served[name]} and {key} -- one public "
                                "name resolves to one host, so one of these routers is dead config")

    registry = registry_domains(in_scope, problems)
    for name, key, app in registry:
        if served.get(name) != key:
            problems.append(f"{key}: apps/registry.yml says {app} serves {name} on {key}, but no router "
                            f"on {key} has Host(`{name}`) -- the registry or the router has drifted")
    registered = {name for name, _, _ in registry}

    for name, entry in sorted(overrides.items()):
        entry = entry or {}
        if name not in served:
            problems.append(f"{CONFIG}: {name} is served by no router on an in-scope host -- "
                            "remove the entry, or declare it under off_platform: with a reason")
        if "skip" in entry and not str(entry["skip"] or "").strip():
            problems.append(f"{CONFIG}: {name}: skip needs a reason")
        if "skip" in entry and name in registered:
            problems.append(f"{CONFIG}: {name} is a domain in apps/registry.yml and cannot be "
                            "skipped -- every registry domain has a check")

    checks = []
    for name in sorted(served):
        entry = overrides.get(name) or {}
        if "skip" in entry:
            continue
        checks.append({"hostname": name, "host": served[name], "url": url_for(name, entry.get("path"))})
    return checks + off_platform_checks(off, served, overrides, {h["key"] for h in hosts}, problems)


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    os.chdir(pathlib.Path(args[0] if args else ".").resolve())
    problems = []
    checks = derive(problems)
    if "--json" in sys.argv[1:] and not problems:
        print(json.dumps(checks, indent=2))
        return 0
    for p in problems:
        print(p)
    if problems:
        print(f"{len(problems)} public endpoint problem(s)")
        return 1
    for c in checks:
        extra = []
        if c.get("probes"):
            extra.append(f"probes {', '.join(c['probes'])}")
        if c.get("frequency"):
            extra.append(f"every {c['frequency']}")
        print(f"  {c['host']:8} {c['url']}" + (f"   [{'; '.join(extra)}]" if extra else ""))
    off = sum(1 for c in checks if c.get("off_platform"))
    print(f"public endpoints: {len(checks)} check(s), {off} of them off-platform; "
          "every registry domain is served and checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
