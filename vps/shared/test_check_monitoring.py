#!/usr/bin/env python3
"""Self-check for check-monitoring.py.  Run: python3 vps/shared/test_check_monitoring.py

Each case builds a tiny fake repository -- a hosts.json, a stack or two, a metric allowlist,
a dashboard, an alert rule -- and asserts the checker's verdict. The cases that matter are
the failures, because each is a way monitoring rots without anyone noticing:

  - an allowlisted metric no panel or rule reads    -> series budget spent on nothing
  - a panel or rule reading a metric not allowlisted -> an empty panel, a rule that never fires
  - a container in a compose file the down-alert does not declare -> it can die silently
  - a down-alert selector without the host matcher  -> an alert that names the wrong instance
  - an off-platform check with no rule to alert it  -> a name probed and watched by nobody
  - an endpoint rule pinned to host="<vps>"         -> the same, with the file looking correct

The last case runs the checker against this repository itself.
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import textwrap

SCRIPT = pathlib.Path(__file__).with_name("check-monitoring.py")
REPO = SCRIPT.parents[2]


def repo(hosts, files):
    """Write a fake repo: hosts is the hosts.json list, files maps rel path -> text or object."""
    root = pathlib.Path(tempfile.mkdtemp())
    (root / "vps").mkdir()
    (root / "vps" / "hosts.json").write_text(json.dumps(hosts), encoding="utf-8")
    for rel, content in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps(content) if not isinstance(content, str) else textwrap.dedent(content)
        p.write_text(text, encoding="utf-8")
    return root


def expect(name, root, rc, *needles):
    r = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert r.returncode == rc, f"{name}: expected rc={rc}, got {r.returncode}\n{out}"
    for n in needles:
        assert n in out, f"{name}: expected {n!r} in output\n{out}"


H1 = [{"key": "h1", "dir": "vps/h1", "env_name": "prod",
       "fanout": {"app": [{"dir": "app-staging", "env_name": "staging"},
                          {"dir": "app-prod", "env_name": "prod"}]}}]

APP = """
    services:
      web:
        image: nginx
        container_name: app-web-${ENV_NAME}
"""
PROXY = """
    services:
      proxy:
        image: traefik
        container_name: proxy
"""
MONITORING = """
    services:
      alloy:
        build: .
        container_name: alloy
        environment:
          MONITORING_HOST: h1
        volumes:
          - textfile:/textfile:ro
    volumes:
      textfile:
        external: true
        name: monitoring_textfile
"""
CONFIG = """
    prometheus.exporter.unix "host" {
      set_collectors = ["cpu", "textfile"]
      textfile {
        directory = "/textfile"
      }
    }
"""
ALLOWLIST = "node_cpu_seconds_total\ncontainer_last_seen\n"


def dashboard(*exprs):
    return {"title": "Hosts", "panels": [{"targets": [{"expr": e}]} for e in exprs],
            "templating": {"list": [{"name": "host",
                                     "query": {"query": "label_values(node_cpu_seconds_total, host)"}}]}}


def down(host, containers):
    expr = "\nor ".join(f'absent_over_time(container_last_seen{{host="{host}", container="{c}"}}[3m])'
                        for c in containers)
    return f"""
        apiVersion: 1
        groups:
          - name: containers
            folder: Monitoring
            interval: 1m
            rules:
              - uid: container-down-{host}
                title: Container down
                condition: C
                data:
                  - refId: A
                    datasourceUid: grafanacloud-prom
                    model:
                      expr: {json.dumps(expr)}
    """


def heartbeat(uid, *exprs):
    """A rule group holding one rule per (uid, expr) -- for the per-host staleness rules."""
    rules = "".join(f"""
              - uid: {u}
                title: {u}
                condition: C
                data:
                  - refId: A
                    datasourceUid: grafanacloud-prom
                    model:
                      expr: {json.dumps(e)}""" for u, e in zip(uid, exprs))
    return f"""
        apiVersion: 1
        groups:
          - name: heartbeats
            folder: Monitoring
            interval: 1m
            rules:{rules}
    """


PROBES_STALE = 'absent_over_time(probes_last_success_timestamp_seconds{host="h1"}[15m])'


def base(**over):
    files = {
        "vps/h1/stacks/app/docker-compose.yml": APP,
        "vps/h1/stacks/proxy/docker-compose.yml": PROXY,
        "vps/h1/stacks/monitoring/docker-compose.yml": MONITORING,
        "vps/h1/stacks/monitoring/metrics.allowlist": ALLOWLIST + "probes_last_success_timestamp_seconds\n",
        "vps/h1/stacks/monitoring/config.alloy": CONFIG,
        "grafana/dashboards/hosts.json": dashboard('sum by (host) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))'),
        "grafana/rules/containers.yml": down("h1", ["app-web-staging", "app-web-prod", "proxy"]),
        "grafana/rules/heartbeats.yml": heartbeat(["probes-stale-h1"], PROBES_STALE),
    }
    files.update(over)
    return repo(H1, {k: v for k, v in files.items() if v is not None})


# Clean: every allowlisted metric is read, every read metric is allowlisted, and the down
# rule declares exactly the compose containers -- fanout resolved, the agent itself exempt.
expect("clean", base(), 0)

# Every host is in scope unless hosts.json says why not (#25). A host with no agent is a host
# whose containers die silently -- so its absence is a failure, not a quiet skip.
expect("in-scope host without a monitoring stack",
       repo([{"key": "h2", "dir": "vps/h2", "env_name": "prod"}],
            {"vps/h2/stacks/proxy/docker-compose.yml": PROXY}),
       1, "h2", "no monitoring stack", "no_monitoring")
# The exemption is a decision, so it carries its reason, and every run prints it -- clean or not.
expect("exempt host",
       repo([{"key": "h2", "dir": "vps/h2", "env_name": "prod", "no_monitoring": "Teeko host, out of scope (#22)"}],
            {"vps/h2/stacks/proxy/docker-compose.yml": PROXY}),
       0, "NOT monitored", "h2: Teeko host, out of scope (#22)")
expect("exemption without a reason",
       repo([{"key": "h2", "dir": "vps/h2", "env_name": "prod", "no_monitoring": " "}],
            {"vps/h2/stacks/proxy/docker-compose.yml": PROXY}),
       1, "no_monitoring needs a reason")
# Exempt AND carrying an agent: the scope decision and the repo disagree, one of them is wrong.
exempt_with_stack = base()
hosts = json.loads((exempt_with_stack / "vps/hosts.json").read_text(encoding="utf-8"))
hosts[0]["no_monitoring"] = "out of scope"
(exempt_with_stack / "vps/hosts.json").write_text(json.dumps(hosts), encoding="utf-8")
expect("exempt host that still has a monitoring stack", exempt_with_stack, 1,
       "declared no_monitoring", "stacks/monitoring")

# Alloy joins the allowlist's lines with | into one regex, so every line must be a bare
# metric name: a comment would become an alternative, and a ( or . in it changes the regex.
expect("allowlist comment", base(**{"vps/h1/stacks/monitoring/metrics.allowlist":
                                    "# host (node)\n" + ALLOWLIST}), 1, "# host (node)", "not a metric name")
expect("allowlist blank line", base(**{"vps/h1/stacks/monitoring/metrics.allowlist":
                                       "node_cpu_seconds_total\n\ncontainer_last_seen\n"}), 1, "line 2")

expect("allowlisted but unread",
       base(**{"vps/h1/stacks/monitoring/metrics.allowlist": ALLOWLIST + "node_load1\n"}),
       1, "node_load1", "no panel or rule")

expect("read but not allowlisted",
       base(**{"grafana/dashboards/hosts.json":
               dashboard("node_cpu_seconds_total", "container_memory_working_set_bytes")}),
       1, "container_memory_working_set_bytes", "grafana/dashboards/hosts.json", "not in")

expect("compose container undeclared",
       base(**{"grafana/rules/containers.yml": down("h1", ["app-web-prod", "proxy"])}),
       1, "app-web-staging", "container-down-h1")

expect("declared container in no compose file",
       base(**{"grafana/rules/containers.yml":
               down("h1", ["app-web-staging", "app-web-prod", "proxy", "ghost"])}),
       1, "ghost", "in no compose file")

expect("no down rule for a monitored host",
       base(**{"grafana/rules/containers.yml": down("other", ["proxy"])}),
       1, "container-down-h1")

wrong_host = down("h1", ["app-web-staging", "app-web-prod", "proxy"]).replace(
    '{host=\\"h1\\", container=\\"proxy\\"}', '{container=\\"proxy\\"}')
assert wrong_host != down("h1", ["app-web-staging", "app-web-prod", "proxy"]), "fixture did not change"
expect("selector without host matcher",
       base(**{"grafana/rules/containers.yml": wrong_host}), 1, 'host="h1"')

# The agent stamps MONITORING_HOST as the `host` label; the rules match host="<key>". If the
# two differ, every selector matches nothing and the down rule fires for every container.
expect("host label differs from key",
       base(**{"vps/h1/stacks/monitoring/docker-compose.yml": MONITORING.replace("MONITORING_HOST: h1",
                                                                                 "MONITORING_HOST: srv123")}),
       1, "MONITORING_HOST", "srv123")
expect("host label missing",
       base(**{"vps/h1/stacks/monitoring/docker-compose.yml": MONITORING.replace("MONITORING_HOST: h1",
                                                                                 "TZ: UTC")}),
       1, "MONITORING_HOST")

# The textfile seam (#24, docs/textfile-metrics.md): producers write *.prom into the shared
# monitoring_textfile volume; the agent must mount it read-only at /textfile and read it there.
# Without the mount every producer's signal is written and never read -- and a staleness rule
# would read that as "the backup stopped", not "monitoring cannot see".
expect("textfile volume not mounted",
       base(**{"vps/h1/stacks/monitoring/docker-compose.yml":
               MONITORING.replace("          - textfile:/textfile:ro\n", "")}),
       1, "monitoring_textfile", "/textfile")
expect("textfile volume mounted writable",
       base(**{"vps/h1/stacks/monitoring/docker-compose.yml":
               MONITORING.replace("textfile:/textfile:ro", "textfile:/textfile")}),
       1, "read-only")
expect("textfile mount is some other volume",
       base(**{"vps/h1/stacks/monitoring/docker-compose.yml":
               MONITORING.replace("name: monitoring_textfile", "name: scratch")}),
       1, "monitoring_textfile")
# Compose's long volume syntax is the same mount; it must not read as missing.
expect("textfile volume in long syntax",
       base(**{"vps/h1/stacks/monitoring/docker-compose.yml": MONITORING.replace(
           "          - textfile:/textfile:ro\n",
           "          - type: volume\n            source: textfile\n            target: /textfile\n"
           "            read_only: true\n")}), 0)
expect("no config.alloy",
       base(**{"vps/h1/stacks/monitoring/config.alloy": None}), 1, "no vps/h1/stacks/monitoring/config.alloy")
expect("textfile collector not enabled",
       base(**{"vps/h1/stacks/monitoring/config.alloy": CONFIG.replace(', "textfile"', "")}),
       1, "config.alloy", "textfile")
expect("textfile collector reads another directory",
       base(**{"vps/h1/stacks/monitoring/config.alloy": CONFIG.replace('"/textfile"', '"/tmp"')}),
       1, "config.alloy", "/textfile")

# A textfile producer's metrics are agent-collected like node_*: a rule reading one that is
# not allowlisted is a rule that can never fire.
expect("textfile metric read but not allowlisted",
       base(**{"grafana/dashboards/hosts.json":
               dashboard("node_cpu_seconds_total", "container_last_seen",
                         "time() - backup_last_success_timestamp_seconds")}),
       1, "backup_last_success_timestamp_seconds", "not in")

# The rules that watch for SILENCE cannot be written once for all hosts: absent_over_time has
# to name the host, or a host whose agent never started matches nothing and fires nothing.
# So each monitored host must carry its own -- probes-stale always, backup-stale when the host
# runs a backup job -- each selector pinned to that host.
expect("no probes-stale rule for a monitored host",
       base(**{"grafana/rules/heartbeats.yml": heartbeat(["probes-stale-other"],
                                                         PROBES_STALE.replace("h1", "other"))}),
       1, "probes-stale-h1")
expect("probes-stale selector without host matcher",
       base(**{"grafana/rules/heartbeats.yml": heartbeat(["probes-stale-h1"],
                                                         "absent_over_time(probes_last_success_timestamp_seconds[15m])")}),
       1, "probes-stale-h1", 'host="h1"')
BACKUP_STALE = 'absent_over_time(backup_last_success_timestamp_seconds{host="h1"}[15m])'
with_backup = {"vps/h1/stacks/backup/docker-compose.yml": "services:\n  backup:\n    image: b\n    container_name: backup\n",
               "vps/h1/stacks/monitoring/metrics.allowlist": ALLOWLIST + "probes_last_success_timestamp_seconds\n"
                                                             "backup_last_success_timestamp_seconds\n",
               "grafana/rules/containers.yml": down("h1", ["app-web-staging", "app-web-prod", "proxy", "backup"])}
expect("backup job but no backup-stale rule", base(**with_backup), 1, "backup-stale-h1")
expect("backup job with its backup-stale rule",
       base(**with_backup, **{"grafana/rules/heartbeats.yml": heartbeat(["probes-stale-h1", "backup-stale-h1"],
                                                                        PROBES_STALE, BACKUP_STALE)}), 0)

# The agent is one implementation. CI rsyncs only a stack's own directory, so every host carries
# a copy -- and a fix that reached one copy leaves the other host running the bug. Only the
# compose file (which names the host) and ci/ may differ.
H12 = [{"key": "h1", "dir": "vps/h1", "env_name": "prod"}, {"key": "h2", "dir": "vps/h2", "env_name": "prod"}]


def two_hosts(**over):
    files = {"grafana/dashboards/hosts.json": dashboard('rate(node_cpu_seconds_total[5m])', "container_last_seen",
                                                        "probes_last_success_timestamp_seconds")}
    for h in ("h1", "h2"):
        files.update({
            f"vps/{h}/stacks/proxy/docker-compose.yml": PROXY,
            f"vps/{h}/stacks/monitoring/docker-compose.yml": MONITORING.replace("MONITORING_HOST: h1", f"MONITORING_HOST: {h}"),
            f"vps/{h}/stacks/monitoring/metrics.allowlist": ALLOWLIST + "probes_last_success_timestamp_seconds\n",
            f"vps/{h}/stacks/monitoring/config.alloy": CONFIG,
            f"vps/{h}/stacks/monitoring/Dockerfile": "FROM grafana/alloy:v1\n",
            f"vps/{h}/stacks/monitoring/probes/bin/lib.sh": "echo probe\n",
            f"grafana/rules/containers-{h}.yml": down(h, ["proxy"]).replace("name: containers", f"name: containers-{h}"),
            f"grafana/rules/heartbeats-{h}.yml": heartbeat([f"probes-stale-{h}"], PROBES_STALE.replace("h1", h))
                                                 .replace("name: heartbeats", f"name: heartbeats-{h}"),
        })
    files.update(over)
    return repo(H12, files)


# The two compose files differ (MONITORING_HOST) -- that is allowed.
expect("two identical agents", two_hosts(), 0)
expect("agent config drifted between hosts",
       two_hosts(**{"vps/h2/stacks/monitoring/config.alloy": CONFIG + "// hotfix\n"}),
       1, "monitoring drift", "config.alloy")
missing = two_hosts()
(missing / "vps/h2/stacks/monitoring/probes/bin/lib.sh").unlink()
expect("probe script missing on one host", missing, 1, "monitoring drift", "probes/bin/lib.sh", "missing on h2")

# ── Off-platform checks (#37) ────────────────────────────────────────────────────────────────
# booking-system's frontends are on Vercel, so their checks carry host: vercel rather than a VPS
# key. They are alerted on only by the two rules that read every job -- and only for as long as
# nobody pins those rules to a host.
OFF_PLATFORM = """
    off_platform:
      www.vendor.example:
        reason: the marketing site, served by a PaaS -- no router here has it
        platform: paas
"""
ENDPOINT_RULES = heartbeat(
    ["endpoint-down", "tls-expiry"],
    "max by (instance, job) (max_over_time(probe_success[2m]))",
    "min by (instance, job) (probe_ssl_earliest_cert_expiry) - time()")

expect("off-platform name with the rules that cover it",
       base(**{"grafana/synthetic/endpoints.yml": OFF_PLATFORM,
               "grafana/rules/endpoints.yml": ENDPOINT_RULES}), 0)

# No file, or no off_platform block: nothing to check, and the absence is not a failure.
expect("no synthetic config at all", base(), 0)
expect("synthetic config with no off_platform block",
       base(**{"grafana/synthetic/endpoints.yml": "probes: [Singapore]\n"}), 0)

expect("off-platform name with no endpoint rules",
       base(**{"grafana/synthetic/endpoints.yml": OFF_PLATFORM}), 1,
       "endpoint-down", "never alerted")

expect("off-platform name with no tls rule",
       base(**{"grafana/synthetic/endpoints.yml": OFF_PLATFORM,
               "grafana/rules/endpoints.yml": heartbeat(
                   ["endpoint-down"], "max by (instance, job) (max_over_time(probe_success[2m]))")}),
       1, "tls-expiry", "never alerted")

# The failure that looks fine in review: someone quietens a VPS by adding a host matcher, and
# every name that host does not serve silently stops being alerted on.
expect("endpoint rule pinned to a VPS host",
       base(**{"grafana/synthetic/endpoints.yml": OFF_PLATFORM,
               "grafana/rules/endpoints.yml": heartbeat(
                   ["endpoint-down", "tls-expiry"],
                   'max by (instance, job) (max_over_time(probe_success{host="h1"}[2m]))',
                   "min by (instance, job) (probe_ssl_earliest_cert_expiry) - time()")}),
       1, 'host="h1"', "paas", "www.vendor.example")

expect("this repository", REPO, 0)

print("check-monitoring.py: all checks passed")
