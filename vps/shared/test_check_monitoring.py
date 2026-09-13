#!/usr/bin/env python3
"""Self-check for check-monitoring.py.  Run: python3 vps/shared/test_check_monitoring.py

Each case builds a tiny fake repository -- a hosts.json, a stack or two, a metric allowlist,
a dashboard, an alert rule -- and asserts the checker's verdict. The cases that matter are
the failures, because each is a way monitoring rots without anyone noticing:

  - an allowlisted metric no panel or rule reads    -> series budget spent on nothing
  - a panel or rule reading a metric not allowlisted -> an empty panel, a rule that never fires
  - a container in a compose file the down-alert does not declare -> it can die silently
  - a down-alert selector without the host matcher  -> an alert that names the wrong instance

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


def base(**over):
    files = {
        "vps/h1/stacks/app/docker-compose.yml": APP,
        "vps/h1/stacks/proxy/docker-compose.yml": PROXY,
        "vps/h1/stacks/monitoring/docker-compose.yml": MONITORING,
        "vps/h1/stacks/monitoring/metrics.allowlist": ALLOWLIST,
        "grafana/dashboards/hosts.json": dashboard('sum by (host) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))'),
        "grafana/rules/containers.yml": down("h1", ["app-web-staging", "app-web-prod", "proxy"]),
    }
    files.update(over)
    return repo(H1, {k: v for k, v in files.items() if v is not None})


# Clean: every allowlisted metric is read, every read metric is allowlisted, and the down
# rule declares exactly the compose containers -- fanout resolved, the agent itself exempt.
expect("clean", base(), 0)

# A host without a monitoring stack is not checked here -- rolling out is #25's job.
expect("no monitoring stack", repo([{"key": "h2", "dir": "vps/h2", "env_name": "prod"}],
                                   {"vps/h2/stacks/proxy/docker-compose.yml": PROXY}), 0)

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

expect("this repository", REPO, 0)

print("check-monitoring.py: all checks passed")
