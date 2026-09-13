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

The last case runs the checker against this repository itself.
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import textwrap

SCRIPT = pathlib.Path(__file__).with_name("public-endpoints.py")
REPO = SCRIPT.parents[2]

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

expect("this repository", REPO, 0)

print("public-endpoints.py: all checks passed")
