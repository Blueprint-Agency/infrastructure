#!/usr/bin/env python3
"""Self-check for public-endpoints.py.  Run: python3 vps/shared/test_public_endpoints.py

Each case builds a tiny fake repository -- hosts.json, a registry, a compose file or a Traefik
dynamic file, grafana/synthetic/endpoints.yml -- and asserts the checker's verdict and the
checks it would create. The failures are the point, because each is a way a public name ends
up unwatched:

  - a registry domain no router on its host serves      -> the registry has drifted
  - a router name whose ${VAR} has no value              -> a name we cannot probe
  - a registry domain skipped                            -> a registry domain with no check
  - a skip with no reason, or an entry for no router     -> exceptions that rot
  - an off_platform entry with no reason or no platform  -> a hand-typed name nobody can review
  - an off_platform name a router here DOES serve        -> a hand-typed copy of a derived one

The last case runs the checker against this repository itself.
"""
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import textwrap

SCRIPT = pathlib.Path(__file__).with_name("public-endpoints.py")
REPO = SCRIPT.parents[2]

# Imported as well as run: the free-tier arithmetic (#42) is a pure function, and checking it
# through a subprocess's printed total would only prove the formatting.
_spec = importlib.util.spec_from_file_location("public_endpoints", SCRIPT)
pe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pe)

HOSTS = [
    {"key": "h1", "dir": "vps/h1", "env_name": "prod",
     "fanout": {"app": [{"dir": "app-staging", "env_name": "staging"},
                        {"dir": "app-prod", "env_name": "prod"}]}},
    {"key": "old", "dir": "vps/old", "env_name": "prod", "no_backups": "out of scope"},
]

REGISTRY = """
    apps:
      - name: app
        vps:
          staging: h1
          production: h1
        domain:
          staging: dev.example.com
          production: example.com
      - name: legacy
        vps:
          production: old
        domain:
          production: legacy.example.com
"""

APP = """
    services:
      web:
        image: nginx
        container_name: app-web-${ENV_NAME}
        labels:
          - "traefik.http.routers.web-${ENV_NAME}.rule=Host(`${APP_FQDN}`)"
"""

PROXY = """
    services:
      traefik:
        image: traefik
        labels:
          traefik.http.routers.dashboard.rule: Host(`traefik-h1.${BASE_DOMAIN}`)
          traefik.http.routers.catchall.rule: hostregexp(`.+`)
"""

DYNAMIC = """
    http:
      routers:
        mail:
          rule: "Host(`mail.example.com`) || Host(`mail.alias.com`)"
"""

LEGACY = """
    services:
      web:
        image: nginx
        labels:
          - "traefik.http.routers.legacy.rule=Host(`legacy.example.com`)"
"""

ENDPOINTS = """
    vars:
      "*": {BASE_DOMAIN: example.org}
      h1/app-staging: {APP_FQDN: dev.example.com}
      h1/app-prod: {APP_FQDN: example.com}
    endpoints:
      traefik-h1.example.org:
        skip: router exists but the name has no DNS record
      mail.example.com:
        path: /account
"""

# A name nothing here serves, typed by hand because nothing can derive it (#37).
OFF = """
    off_platform:
      www.vendor.example:
        reason: the marketing site, served by a PaaS -- no router here has it
        platform: paas
        path: /status
        probes: [Singapore]
        frequency: 300s
"""


def repo(**over):
    files = {
        "apps/registry.yml": REGISTRY,
        "vps/h1/stacks/app/docker-compose.yml": APP,
        "vps/h1/stacks/traefik/docker-compose.yml": PROXY,
        "vps/h1/stacks/traefik/dynamic/mail.yml": DYNAMIC,
        "vps/old/stacks/web/docker-compose.yml": LEGACY,
        "grafana/synthetic/endpoints.yml": ENDPOINTS,
    }
    files.update(over)
    root = pathlib.Path(tempfile.mkdtemp())
    (root / "vps").mkdir()
    (root / "vps" / "hosts.json").write_text(json.dumps(HOSTS), encoding="utf-8")
    for rel, text in files.items():
        if text is None:
            continue
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(text), encoding="utf-8")
    return root


def run(root, *args):
    r = subprocess.run([sys.executable, str(SCRIPT), str(root), *args], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def expect(name, root, rc, *needles):
    got, out = run(root)
    assert got == rc, f"{name}: expected rc={rc}, got {got}\n{out}"
    for n in needles:
        assert n in out, f"{name}: expected {n!r} in output\n{out}"


# Clean: every registry domain on an in-scope host is served by a router there, every
# ${VAR} resolves, and the checks are every router name minus the reasoned skips.
expect("clean", repo(), 0)
rc, out = run(repo(), "--json")
assert rc == 0, out
checks = {c["hostname"]: c for c in json.loads(out)}
assert sorted(checks) == ["dev.example.com", "example.com", "mail.alias.com", "mail.example.com"], sorted(checks)
assert checks["dev.example.com"]["host"] == "h1"
assert checks["mail.example.com"]["url"] == "https://mail.example.com/account"
assert checks["example.com"]["url"] == "https://example.com/"
# A host out of scope (no_backups: <reason>) contributes nothing, not even its registry domain.
assert "legacy.example.com" not in checks
# hostregexp is a catch-all, not a public name.
assert not any("+" in h for h in checks)

expect("registry domain no router serves",
       repo(**{"vps/h1/stacks/traefik/dynamic/mail.yml": None,
               "grafana/synthetic/endpoints.yml": ENDPOINTS.replace("mail.example.com:\n        path: /account\n", ""),
               "apps/registry.yml": REGISTRY + "      - name: mail\n        vps: {production: h1}\n"
                                              "        domain: {production: mail.example.com}\n"}),
       1, "mail.example.com", "no router")

expect("unresolved variable",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS.replace("      h1/app-prod: {APP_FQDN: example.com}\n", "")}),
       1, "${APP_FQDN}", "app-prod")

expect("registry domain skipped",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + "      example.com:\n        skip: noisy\n"}),
       1, "example.com", "registry")

expect("skip without a reason",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS.replace(
           "skip: router exists but the name has no DNS record", "skip: ''")}),
       1, "traefik-h1.example.org", "reason")

expect("entry for a name no router serves",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + "      gone.example.com:\n        path: /\n"}),
       1, "gone.example.com")

# Host(`a`, `b`) passes YAML and the file provider, then fails at router build on Traefik v3.3
# and the router ceases to exist (CLAUDE.md, 2026-09-12). Reading no name from it would hide
# exactly the outage these checks are for.
expect("multi-argument Host()",
       repo(**{"vps/h1/stacks/traefik/dynamic/mail.yml": DYNAMIC.replace(
           "Host(`mail.example.com`) || Host(`mail.alias.com`)", "Host(`mail.example.com`, `mail.alias.com`)")}),
       1, "mail.yml", "one name")

# ${X:-default} is compose syntax the resolver does not read -- it must not become a literal URL.
expect("unsupported variable syntax",
       repo(**{"vps/h1/stacks/traefik/docker-compose.yml": PROXY.replace("${BASE_DOMAIN}", "${BASE_DOMAIN:-x.org}")}),
       1, "BASE_DOMAIN:-x.org")

# One name on two hosts: which host the alert names would depend on file order.
hosts2 = HOSTS + [{"key": "h2", "dir": "vps/h2", "env_name": "prod"}]
root = repo(**{"vps/h2/stacks/web/docker-compose.yml": LEGACY.replace("legacy.example.com", "mail.alias.com")})
(root / "vps" / "hosts.json").write_text(json.dumps(hosts2), encoding="utf-8")
expect("a name served on two hosts", root, 1, "mail.alias.com", "h1", "h2")

# A registry entry whose vps is a list cannot say which environment's domain is where. On an
# in-scope host it must fail, not slip past "every registry domain has a check".
expect("registry vps as a list on an in-scope host",
       repo(**{"apps/registry.yml": REGISTRY + "      - name: tool\n        vps: [h1]\n"
                                               "        domain: {production: tool.example.com}\n"}),
       1, "tool", "list")

# ── off_platform (#37) ───────────────────────────────────────────────────────────────────────
# A declared off-platform name becomes a check like any other, with the platform as its `host`
# label and its own probes and frequency. Everything derived is untouched.
expect("off-platform name declared", repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + OFF}), 0,
       "off-platform")
rc, out = run(repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + OFF}), "--json")
assert rc == 0, out
checks = {c["hostname"]: c for c in json.loads(out)}
assert "www.vendor.example" in checks, sorted(checks)
off = checks["www.vendor.example"]
assert off["host"] == "paas" and off["url"] == "https://www.vendor.example/status", off
assert off["probes"] == ["Singapore"] and off["off_platform"] is True, off
# 300s is written down as 5m: ONE canonical spelling per cadence, because the string is the
# check's `cadence` label and the label is what the per-cadence endpoint-down rule matches (#42).
# Two spellings would be two tiers, one of which no rule covers and nothing would report.
assert off["frequency"] == "5m", off
# The derived ones keep the file-wide probes -- no key of their own to override with -- and the
# file-wide frequency, which this fixture does not set, so it is the one-minute default.
assert "probes" not in checks["example.com"] and "off_platform" not in checks["example.com"]
assert checks["example.com"]["frequency"] == "1m", checks["example.com"]

# The reason is the whole point of the block: without it nobody can review, years later, why a
# name nothing here serves is being probed from our budget. Same rule as skip:.
expect("off-platform without a reason",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + OFF.replace(
           "reason: the marketing site, served by a PaaS -- no router here has it", "reason: ''")}),
       1, "www.vendor.example", "reason")
expect("off-platform with no reason key at all",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + """
    off_platform:
      www.vendor.example:
        platform: paas
"""}), 1, "www.vendor.example", "reason")

# The platform becomes the check's `host` label, which is what every alert prints and every
# silence matches. Blank, and the alert says "www.vendor.example on ".
expect("off-platform without a platform",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + OFF.replace("platform: paas", "platform: ''")}),
       1, "www.vendor.example", "platform")

# ...and it must not be a VPS host key, or `endpoint-down` sends someone to ssh a healthy box.
expect("off-platform platform naming a VPS host",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + OFF.replace("platform: paas", "platform: h1")}),
       1, "www.vendor.example", "vps/hosts.json")

# A name a router here DOES serve is derived already. Keeping a hand-typed copy means two
# declarations that will disagree, and the hand-typed one is the one that rots.
expect("off-platform name a router serves",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + OFF.replace(
           "www.vendor.example", "example.com")}),
       1, "example.com", "router on h1")

# One name, one declaration.
expect("name under both blocks",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + "      mail.alias.com:\n        path: /\n"
                                                  + OFF.replace("www.vendor.example", "mail.alias.com")}),
       1, "mail.alias.com", "both")

# The knobs are typed: a frequency the apply script cannot parse, or probes that are not a list
# of names, would each fail at apply time instead of in CI.
expect("off-platform frequency that is not a duration",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + OFF.replace("frequency: 300s", "frequency: 5")}),
       1, "www.vendor.example", "frequency")
expect("off-platform probes that are not a list",
       repo(**{"grafana/synthetic/endpoints.yml": ENDPOINTS + OFF.replace(
           "probes: [Singapore]", "probes: Singapore")}),
       1, "www.vendor.example", "probes")

# ── cadence and the free-tier budget (#42) ───────────────────────────────────────────────────
# The file-wide frequency is the default for every check in both blocks, and an entry in either
# may override it. The free tier counts executions per probe per run, so this is the only knob
# that changes the bill other than the probe list.
CADENCE = ENDPOINTS.replace("    vars:", "    frequency: 15m\n    probes: [Singapore]\n    vars:")
CADENCE = CADENCE.replace("      mail.example.com:\n        path: /account\n",
                          "      mail.example.com:\n        path: /account\n        frequency: 2m\n")
rc, out = run(repo(**{"grafana/synthetic/endpoints.yml": CADENCE + OFF}), "--json")
assert rc == 0, out
checks = {c["hostname"]: c for c in json.loads(out)}
assert checks["mail.example.com"]["frequency"] == "2m", checks["mail.example.com"]
assert checks["example.com"]["frequency"] == "15m", checks["example.com"]
assert checks["www.vendor.example"]["frequency"] == "5m", checks["www.vendor.example"]

# ...and the bill those cadences add up to, which is what `public-endpoints.py` prints. A
# 30-day month is 43,200 minutes; one probe every 15m is 2,880 executions, every 2m is 21,600.
one = [{"frequency": "15m"}, {"frequency": "2m"}]
assert pe.executions_per_month(one, ["Singapore"]) == 2880 + 21600
# Probes multiply it -- three probes is three times the bill, which is why #42 cut the list to
# one rather than only slowing the interval.
assert pe.executions_per_month([{"frequency": "15m", "probes": ["a", "b", "c"]}], ["Singapore"]) == 8640

# A frequency that does not parse, or one under Synthetic Monitoring's floor, fails in CI rather
# than at apply time -- in EITHER block, and file-wide too.
expect("endpoints frequency that is not a duration",
       repo(**{"grafana/synthetic/endpoints.yml": CADENCE.replace("frequency: 2m", "frequency: soon")}),
       1, "mail.example.com", "frequency")
expect("file-wide frequency that is not a duration",
       repo(**{"grafana/synthetic/endpoints.yml": CADENCE.replace("    frequency: 15m", "    frequency: 15")}),
       1, "frequency")
# Synthetic Monitoring accepts 30s..1h for an HTTP check (measured against the account with
# POST /api/v1/check/validate, 2026-09-20). Outside it, CI has to say so: the alternative is a
# cadence label and a matching endpoint-down rule written for a frequency the API then refuses.
expect("frequency under Synthetic Monitoring's floor",
       repo(**{"grafana/synthetic/endpoints.yml": CADENCE.replace("frequency: 2m", "frequency: 5s")}),
       1, "mail.example.com", "30s to 3600s")
expect("frequency over Synthetic Monitoring's ceiling",
       repo(**{"grafana/synthetic/endpoints.yml": CADENCE.replace("frequency: 2m", "frequency: 2h")}),
       1, "mail.example.com", "30s to 3600s")

# ⚠️ A typo'd key is the quiet one: `frequncy: 2m` would leave the check on the file-wide
# cadence -- a name running at an interval nobody chose, with nothing else in this repository
# in a position to notice. So each block's vocabulary is closed.
expect("typo'd key under endpoints",
       repo(**{"grafana/synthetic/endpoints.yml": CADENCE.replace("        frequency: 2m", "        frequncy: 2m")}),
       1, "mail.example.com", "unknown key")
expect("an entry that is not a mapping at all",
       repo(**{"grafana/synthetic/endpoints.yml": CADENCE.replace(
           "      mail.example.com:\n        path: /account\n        frequency: 2m\n",
           "      mail.example.com: /account\n")}),
       1, "mail.example.com", "expected a mapping")
expect("typo'd key under off_platform",
       repo(**{"grafana/synthetic/endpoints.yml": CADENCE + OFF.replace("        path: /status", "        pth: /status")}),
       1, "www.vendor.example", "unknown key")

expect("this repository", REPO, 0)

print("public-endpoints.py: all checks passed")
