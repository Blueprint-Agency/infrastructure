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

Every check also carries a CADENCE -- how often it runs -- because Synthetic Monitoring's free
tier counts executions per probe per run and the whole allowance is ~2.3 a minute (#42). The
file-wide `frequency:` is the default and an entry in either block may override it. A cadence is
canonicalised, so 120s and 2m are one tier and not two, and becomes the check's `cadence` label:
grafana/rules/endpoints.yml carries one endpoint-down rule per cadence, because that rule's
window has to grow with the interval or the alert flickers on staleness instead of firing.

Fails when:
  - a registry domain on an in-scope host is served by no router on that host (drift);
  - a router's ${VAR} has no value in endpoints.yml (a name nobody can probe);
  - a registry domain is skipped (every registry domain has a check);
  - a skip has no reason, or an endpoints.yml entry names no router (exceptions that rot);
  - an entry in either block carries a key this file does not know: a typo'd `frequncy:` is a
    check silently running at a cadence nobody chose, and nothing else would ever say so;
  - a frequency does not parse, or is outside Synthetic Monitoring's 30s..1h range;
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
DURATION = re.compile(r"([0-9]+)([smh])")
UNITS = {"s": 1, "m": 60, "h": 3600}
# What a check runs at when neither the file nor the entry says. Kept at the interval #24 chose
# so that a file with no `frequency:` behaves as it did before #42 rather than silently slowing.
DEFAULT_FREQUENCY = "1m"
# Synthetic Monitoring's own limits on an HTTP check's frequency, MEASURED against the account
# on 2026-09-20 with POST /api/v1/check/validate (which is the cheap way to ask: it answers
# {"valid": ...} and writes nothing). 29s and 3,660,000 ms are both rejected, 30s and 1h accepted.
# Without these a `frequency: 2h` would pass CI, get a cadence label, get a matching
# endpoint-down-2h rule written, and only then be refused by the API mid-apply.
MIN_FREQUENCY, MAX_FREQUENCY = 30, 3600
# The vocabulary of each block. Anything else is a typo, and a typo in a cadence is a check
# running at an interval nobody chose -- which no other check in this repository would catch.
ENDPOINT_KEYS = {"path", "skip", "frequency"}
OFF_PLATFORM_KEYS = {"reason", "platform", "path", "probes", "frequency"}
# Grafana Cloud's free tier: 100,000 check executions a month, counted PER PROBE PER RUN, and
# the month they state it for is 30 days = 43,200 minutes. So the whole allowance is about 2.3
# executions a minute across every check (#42). main() prints the bill this repo's files add up
# to, next to that ceiling, so the cost of adding a name is visible at the moment it is added.
MONTH_MINUTES = 30 * 24 * 60
FREE_TIER_EXECUTIONS = 100_000


def url_for(name, path):
    path = str(path or "/")
    return f"https://{name}{path if path.startswith('/') else '/' + path}"


def duration_seconds(value):
    """'2m' -> 120. None when it does not parse."""
    m = DURATION.fullmatch(str(value).strip())
    return int(m.group(1)) * UNITS[m.group(2)] if m else None


def executions_per_month(checks, default_probes):
    """The only number the free tier counts: probes x runs, summed over every check (#42)."""
    return sum(len(c.get("probes") or default_probes) * MONTH_MINUTES * 60
               // duration_seconds(c["frequency"]) for c in checks)


def cadence(value, where, problems, fallback=None):
    """'120s' -> '2m'. ONE canonical spelling per interval.

    The string this returns is the check's `cadence` label, and that label is what
    grafana/rules/endpoints.yml's per-cadence endpoint-down rule matches on. If `120s` and `2m`
    stayed two strings they would be two tiers, and one of them would have no rule -- a check
    probed forever and alerted on by nothing, which looks identical to a healthy one.
    """
    if value is None:
        return fallback
    secs = duration_seconds(value)
    if secs is None:
        problems.append(f"{where}: frequency {value!r} -- expected e.g. 60s, 2m, 15m")
        return fallback
    if not MIN_FREQUENCY <= secs <= MAX_FREQUENCY:
        problems.append(f"{where}: frequency {value!r} -- Synthetic Monitoring accepts "
                        f"{MIN_FREQUENCY}s to {MAX_FREQUENCY}s")
        return fallback
    if secs % 3600 == 0:
        return f"{secs // 3600}h"
    return f"{secs // 60}m" if secs % 60 == 0 else f"{secs}s"


def checked_entry(entry, allowed, where, problems):
    """-> the entry as a dict, having reported anything this block does not understand.

    A typo'd key is the quiet failure here: `frequncy: 2m` leaves the check on the file-wide
    cadence -- running at an interval nobody chose, with nothing else in this repository in a
    position to notice. So each block's vocabulary is closed.
    """
    if not isinstance(entry, dict):
        problems.append(f"{where}: expected a mapping of {', '.join(sorted(allowed))}, "
                        f"got {entry!r}")
        return {}
    extra = sorted(set(entry) - allowed)
    if extra:
        problems.append(f"{where}: unknown key(s) {', '.join(extra)} -- this block takes "
                        f"{', '.join(sorted(allowed))}")
    return entry


def off_platform_checks(entries, served, overrides, host_keys, default_cadence, problems):
    """The hand-typed half: names nothing here serves, so nothing here can derive them (#37).

    Every failure below is a way one of these rots unnoticed -- an exception with no stated
    reason, a `host` label that sends someone to ssh a machine that is fine, or a duplicate of
    a name the derived list already covers and will keep covering after this entry goes stale.
    """
    checks = []
    for name, entry in sorted(entries.items()):
        where = f"{CONFIG}: {name}"
        entry = checked_entry(entry or {}, OFF_PLATFORM_KEYS, where, problems)
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
        probes = entry.get("probes")
        if probes is not None and not (isinstance(probes, list) and probes
                                       and all(isinstance(p, str) and p.strip() for p in probes)):
            problems.append(f"{where}: probes must be a non-empty list of probe names, or absent to "
                            f"use the file-wide probes: -- got {probes!r}")
        check = {"hostname": name, "host": platform, "url": url_for(name, entry.get("path")),
                 "frequency": cadence(entry.get("frequency"), where, problems, default_cadence),
                 "off_platform": True}
        if isinstance(probes, list) and probes:
            check["probes"] = [str(p) for p in probes]
        checks.append(check)
    return checks


def derive(problems):
    """-> [check] where a check is {hostname, host, url, frequency} and, off-platform, probes."""
    config = pathlib.Path(CONFIG)
    doc = load_yaml(config) if config.is_file() else {}
    variables, overrides = doc.get("vars") or {}, doc.get("endpoints") or {}
    off = doc.get("off_platform") or {}
    default_cadence = cadence(doc.get("frequency") or DEFAULT_FREQUENCY,
                              f"{CONFIG}: frequency", problems) or DEFAULT_FREQUENCY
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
        entry = checked_entry(entry or {}, ENDPOINT_KEYS, f"{CONFIG}: {name}", problems)
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
        # Already reported by checked_entry above if it is not a mapping; don't crash on it here.
        entry = overrides.get(name) if isinstance(overrides.get(name), dict) else {}
        if "skip" in entry:
            continue
        checks.append({"hostname": name, "host": served[name],
                       "url": url_for(name, entry.get("path")),
                       "frequency": cadence(entry.get("frequency"), f"{CONFIG}: {name}",
                                            problems, default_cadence)})
    return checks + off_platform_checks(off, served, overrides, {h["key"] for h in hosts},
                                        default_cadence, problems)


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
    # Guarded the same way derive() guards it: this script must still run in a checkout with no
    # synthetic config, where it prints the derived names and no budget.
    config = pathlib.Path(CONFIG)
    default_probes = (load_yaml(config) if config.is_file() else {}).get("probes") or []
    for c in checks:
        probes = c.get("probes") or default_probes
        print(f"  {c['host']:8} {c['frequency']:>4}  x{len(probes)}  {c['url']}"
              + (f"   [{', '.join(c['probes'])}]" if c.get("probes") else ""))
    off = sum(1 for c in checks if c.get("off_platform"))
    print(f"public endpoints: {len(checks)} check(s), {off} of them off-platform; "
          "every registry domain is served and checked")
    # The free tier counts executions, not checks, so print the bill rather than the count:
    # "one more name" is a different price at 2 minutes than at 15, and #42 exists because
    # nobody saw the total until a trial was about to end. Not a failure -- a paid plan is a
    # legitimate answer -- but never silent.
    if not default_probes:
        # Never print a reassuring zero: with no probe list the bill is unknown, not free. This
        # is the exact shape of the miss #42 was opened for. grafana-apply.py refuses to run at
        # all in this state, which is the enforcement; here it is only said out loud.
        print(f"free-tier budget: NOT COMPUTABLE -- {CONFIG} lists no probes:, and executions "
              "are counted per probe per run")
        return 0
    used = executions_per_month(checks, default_probes)
    print(f"free-tier budget: {used:,} executions/month of {FREE_TIER_EXECUTIONS:,} "
          f"({used * 100 / FREE_TIER_EXECUTIONS:.0f}%), counted per probe per run over a 30-day "
          "month" + ("  -- OVER the free tier" if used > FREE_TIER_EXECUTIONS else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
